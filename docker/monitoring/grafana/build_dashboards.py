"""Génère les tableaux de bord Grafana (JSON) à partir d'une description compacte.

    python3 docker/monitoring/grafana/build_dashboards.py

Écrire les panneaux en Python plutôt qu'en JSON brut rend les requêtes lisibles et
évite les erreurs de copier-coller. Les fichiers générés sont versionnés dans dashboards/.
"""

import json
from pathlib import Path

OUT = Path(__file__).parent / "dashboards"
PROM = {"type": "prometheus", "uid": "prometheus"}
DWH = {"type": "grafana-postgresql-datasource", "uid": "dwh"}


class Layout:
    """Place les panneaux sur une grille de 24 colonnes, ligne par ligne."""

    def __init__(self):
        self.panels, self.y, self.next_id = [], 0, 1

    def row(self, title):
        self.panels.append(
            {
                "type": "row",
                "title": title,
                "id": self.next_id,
                "collapsed": False,
                "gridPos": {"h": 1, "w": 24, "x": 0, "y": self.y},
            }
        )
        self.next_id += 1
        self.y += 1

    def line(self, panels, height=7):
        x = 0
        for p in panels:
            p["id"] = self.next_id
            p["gridPos"] = {"h": height, "w": p.pop("w"), "x": x, "y": self.y}
            x += p["gridPos"]["w"]
            self.next_id += 1
            self.panels.append(p)
        self.y += height


def prom_target(expr, legend="", ref="A"):
    return {"datasource": PROM, "expr": expr, "legendFormat": legend, "refId": ref}


def stat(title, expr, w=4, unit="none", thresholds=None, mappings=None, legend="", desc="", no_value=None):
    return {
        "type": "stat",
        "title": title,
        "description": desc,
        "w": w,
        "datasource": PROM,
        "targets": [prom_target(expr, legend)],
        "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"]}},
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "mappings": mappings or [],
                **({"noValue": no_value} if no_value else {}),
                "thresholds": {"mode": "absolute", "steps": thresholds or [{"color": "green", "value": None}]},
            },
            "overrides": [],
        },
    }


def series(title, targets, w=12, unit="none", desc="", stack=False):
    return {
        "type": "timeseries",
        "title": title,
        "description": desc,
        "w": w,
        "datasource": PROM,
        "targets": [prom_target(expr, legend, chr(65 + i)) for i, (expr, legend) in enumerate(targets)],
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "custom": {"fillOpacity": 15, "lineWidth": 2, "stacking": {"mode": "normal" if stack else "none"}},
            },
            "overrides": [],
        },
        "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
    }


def sql_panel(title, sql, kind="barchart", w=12, desc="", unit="none", extra_options=None):
    panel = {
        "type": kind,
        "title": title,
        "description": desc,
        "w": w,
        "datasource": DWH,
        "targets": [{"datasource": DWH, "format": "table", "rawQuery": True, "rawSql": sql, "refId": "A", "editorMode": "code"}],
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
        "options": extra_options or {},
    }
    return panel


# Une colonne par métier : Grafana trace une courbe par colonne
METIERS = {
    "chauffage": "Chauffage",
    "plomberie": "Plomberie",
    "electricite": "Électricité",
    "serrurerie": "Serrurerie",
    "peinture": "Peinture",
    "menuiserie": "Menuiserie",
    "petits_travaux": "Petits travaux",
}
COLONNES_METIERS = ", ".join(f"count(*) FILTER (WHERE m.metier_code = '{code}') AS \"{nom}\"" for code, nom in METIERS.items())

UP_MAPPING = [
    {"type": "value", "options": {"0": {"text": "HORS SERVICE", "color": "red"}, "1": {"text": "EN LIGNE", "color": "green"}}}
]
RED_IF_ZERO = [{"color": "red", "value": None}, {"color": "green", "value": 1}]


def plateforme():
    g = Layout()
    g.row("Disponibilité")
    g.line(
        [
            stat("PostgreSQL primaire", 'pg_up{role="primary"}', mappings=UP_MAPPING, thresholds=RED_IF_ZERO),
            stat("PostgreSQL réplica", 'pg_up{role="replica"}', mappings=UP_MAPPING, thresholds=RED_IF_ZERO),
            stat("Kafka (brokers)", "kafka_brokers", thresholds=RED_IF_ZERO),
            stat("Stockage objet", 'up{job="object-storage"}', mappings=UP_MAPPING, thresholds=RED_IF_ZERO),
            stat(
                "Alertes actives",
                'count(ALERTS{alertstate="firing"}) or vector(0)',
                thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
                desc="Détail dans Alertmanager : http://localhost:19093",
            ),
            stat(
                "Dernière sauvegarde (âge)",
                "time() - artelio_backup_last_success_timestamp_seconds",
                unit="s",
                thresholds=[
                    {"color": "green", "value": None},
                    {"color": "orange", "value": 4500},
                    {"color": "red", "value": 7200},
                ],
                desc="Une sauvegarde par heure (RPO 1 h). Orange au-delà de 1 h 15, alerte critique au-delà de 2 h.",
            ),
        ],
        height=5,
    )

    g.row("PostgreSQL")
    g.line(
        [
            series(
                "Transactions validées par seconde",
                [('sum by (role) (rate(pg_stat_database_xact_commit{datname="artelio"}[1m]))', "{{role}}")],
                w=8,
                unit="ops",
            ),
            series(
                "Connexions actives",
                [
                    ('sum by (role) (pg_stat_activity_count{datname="artelio"})', "{{role}}"),
                    ("max(pg_settings_max_connections)", "limite"),
                ],
                w=8,
            ),
            series(
                "Retard de réplication",
                [('pg_replication_lag_seconds{role="replica"}', "réplica")],
                w=8,
                unit="s",
                desc="Temps de retard du réplica sur le primaire. Alerte au-delà de 30 s.",
            ),
        ]
    )
    g.line(
        [
            series(
                "Taille de la base", [('pg_database_size_bytes{datname="artelio", role="primary"}', "artelio")], w=8, unit="bytes"
            ),
            series(
                "Lignes écrites par seconde",
                [
                    ('sum(rate(pg_stat_database_tup_inserted{datname="artelio", role="primary"}[1m]))', "insertions"),
                    ('sum(rate(pg_stat_database_tup_updated{datname="artelio", role="primary"}[1m]))', "mises à jour"),
                    ('sum(rate(pg_stat_database_tup_deleted{datname="artelio", role="primary"}[1m]))', "suppressions"),
                ],
                w=8,
                unit="ops",
            ),
            series(
                "Taux de lecture en cache",
                [
                    (
                        'sum by (role) (rate(pg_stat_database_blks_hit{datname="artelio"}[5m])) / '
                        '(sum by (role) (rate(pg_stat_database_blks_hit{datname="artelio"}[5m])) + '
                        'sum by (role) (rate(pg_stat_database_blks_read{datname="artelio"}[5m])))',
                        "{{role}}",
                    )
                ],
                w=8,
                unit="percentunit",
                desc="Proche de 100 % : la mémoire est bien dimensionnée.",
            ),
        ]
    )

    g.row("Flux temps réel (Kafka)")
    g.line(
        [
            series(
                "Messages reçus par seconde, par topic",
                [('sum by (topic) (rate(kafka_topic_partition_current_offset{topic!~"__.*"}[1m]))', "{{topic}}")],
                w=12,
                unit="ops",
                stack=True,
            ),
            series(
                "Retard des consommateurs",
                [("sum by (consumergroup, topic) (kafka_consumergroup_lag)", "{{consumergroup}} / {{topic}}")],
                w=12,
                desc="Messages pas encore traités par les pipelines du bloc 3. Alerte au-delà de 1 000.",
            ),
        ]
    )

    g.row("Stockage objet et sauvegardes")
    g.line(
        [
            series(
                "Requêtes S3 par seconde",
                [("sum by (type) (rate(SeaweedFS_s3_request_total[1m]))", "{{type}}")],
                w=8,
                unit="reqps",
            ),
            series(
                "Volume stocké par bucket",
                [
                    (
                        'sum by (collection) (SeaweedFS_volumeServer_total_disk_size{type="normal", collection!=""})',
                        "{{collection}}",
                    )
                ],
                w=8,
                unit="bytes",
            ),
            series(
                "Sauvegardes : taille et durée",
                [("artelio_backup_size_bytes", "taille (octets)"), ("artelio_backup_duration_seconds", "durée (s)")],
                w=8,
            ),
        ]
    )
    return dashboard(
        "Plateforme data Artelio",
        "artelio-plateforme",
        g.panels,
        refresh="10s",
        range_="now-1h",
        desc="Santé technique de la plateforme : disponibilité, PostgreSQL, Kafka, stockage, sauvegardes.",
    )


def metier():
    g = Layout()
    g.row("Activité (entrepôt pseudonymisé, lu par le compte analyst sur le réplica)")
    g.line(
        [
            sql_panel(
                "Demandes par mois et par métier (saisonnalité)",
                f"""
            SELECT make_date(d.annee, d.mois, 1) AS "time", {COLONNES_METIERS}
            FROM dwh.fait_demande f JOIN dwh.dim_date d USING (date_key) JOIN dwh.dim_metier m USING (metier_key)
            WHERE d.jour < date_trunc('month', current_date)
            GROUP BY 1 ORDER BY 1""",
                kind="timeseries",
                w=24,
                desc="Le chauffage explose en hiver : c'est cette dérive saisonnière que le modèle IA (bloc 4) doit absorber.",
            ),
        ],
        height=9,
    )
    g.line(
        [
            sql_panel(
                "Demandes par département",
                """
            SELECT z.libelle AS departement, count(*) AS demandes
            FROM dwh.fait_demande f JOIN dwh.dim_zone z USING (zone_key)
            GROUP BY 1 ORDER BY 2 DESC""",
                kind="barchart",
                w=8,
                extra_options={"orientation": "horizontal", "xField": "departement"},
            ),
            sql_panel(
                "Taux de conversion par urgence",
                """
            SELECT urgence, round(100.0 * avg(convertie::int), 1) AS "taux de conversion (%)"
            FROM dwh.fait_demande WHERE urgence IS NOT NULL
            GROUP BY 1 ORDER BY 2 DESC""",
                kind="barchart",
                w=8,
                extra_options={"xField": "urgence"},
            ),
            sql_panel(
                "Délai moyen d'intervention par zone (h)",
                """
            SELECT z.couronne, round(avg(delai_intervention_h), 1) AS "délai moyen (h)"
            FROM dwh.fait_intervention f JOIN dwh.dim_zone z USING (zone_key)
            GROUP BY 1 ORDER BY 2""",
                kind="barchart",
                w=8,
                extra_options={"xField": "couronne"},
                desc="Indicateur d'équité du plan de gouvernance : l'écart entre zones doit rester faible.",
            ),
        ],
        height=8,
    )
    g.line(
        [
            sql_panel(
                "Chiffre d'affaires mensuel (commission Artelio)",
                """
            SELECT make_date(d.annee, d.mois, 1) AS "time", sum(commission_artelio) AS "commission (€)"
            FROM dwh.fait_intervention f JOIN dwh.dim_date d USING (date_key)
            WHERE commission_artelio IS NOT NULL GROUP BY 1 ORDER BY 1""",
                kind="timeseries",
                w=12,
                unit="currencyEUR",
            ),
            sql_panel(
                "Qualité de l'IA : demandes corrigées par un humain (%)",
                """
            SELECT make_date(d.annee, d.mois, 1) AS "time", round(100.0 * avg(correction_humaine::int), 1) AS "corrections (%)"
            FROM dwh.fait_demande f JOIN dwh.dim_date d USING (date_key)
            GROUP BY 1 ORDER BY 1""",
                kind="timeseries",
                w=12,
                unit="percent",
                desc="Supervision humaine du modèle de qualification (AI Act, plan de gouvernance §8).",
            ),
        ],
        height=8,
    )
    return dashboard(
        "Activité métier Artelio",
        "artelio-metier",
        g.panels,
        refresh="",
        range_="now-2y",
        desc="Indicateurs métier calculés sur l'entrepôt en étoile (données pseudonymisées).",
    )


def pipelines():
    """Bloc 3 : flux temps réel (processeurs de flux) et traitements planifiés (Airflow)."""
    g = Layout()
    traites = "sum(rate(artelio_evenements_traites_total[1m]))"
    g.row("Flux temps réel : Kafka → contrôles → PostgreSQL")
    g.line([
        stat("Processeurs actifs", 'count(up{job="pipeline"} == 1) or vector(0)',
             thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 1}, {"color": "green", "value": 2}],
             desc="Deux répliques dans le même groupe Kafka : si l'une tombe, l'autre reprend ses partitions."),
        stat("Débit traité", traites, unit="ops"),
        stat("Taux de rejet (DLQ)",
             "sum(rate(artelio_evenements_rejetes_total[5m])) / sum(rate(artelio_evenements_recus_total[5m]))",
             unit="percentunit", thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 0.05}],
             desc="Événements invalides envoyés dans la file d'erreurs dlq.erreurs. Alerte au-delà de 5 %."),
        stat("Latence p95", "histogram_quantile(0.95, sum by (le) (rate(artelio_traitement_latence_secondes_bucket[5m])))",
             unit="s", thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 2}, {"color": "red", "value": 5}],
             desc="De l'émission de l'événement à son enregistrement en base. Objectif : moins de 5 s."),
        stat("Retard des consommateurs", 'sum(kafka_consumergroup_lag{consumergroup="artelio-stream-processor"})',
             thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 500}, {"color": "red", "value": 1000}]),
        stat("Événements traités (total)", "sum(artelio_evenements_traites_total)"),
    ], height=5)
    g.line([
        series("Événements par seconde", [("sum(rate(artelio_evenements_recus_total[1m]))", "reçus"),
                                          (traites, "écrits en base"),
                                          ("sum(rate(artelio_evenements_rejetes_total[1m]))", "rejetés (DLQ)"),
                                          ("sum(rate(artelio_evenements_doublons_total[1m]))", "doublons ignorés")], w=12, unit="ops"),
        series("Rejets par raison", [("sum by (raison) (rate(artelio_evenements_rejetes_total[5m]))", "{{raison}}")],
               w=12, unit="ops", stack=True, desc="Schéma invalide, JSON cassé, référence inconnue, transition d'état impossible…"),
    ])
    g.line([
        series("Latence de bout en bout", [
            (f"histogram_quantile({q}, sum by (le) (rate(artelio_traitement_latence_secondes_bucket[2m])))", f"p{int(q * 100)}")
            for q in (0.5, 0.95, 0.99)], w=8, unit="s"),
        series("Retard par topic", [('sum by (topic) (kafka_consumergroup_lag{consumergroup="artelio-stream-processor"})', "{{topic}}")], w=8),
        series("Lots : durée p95 et taille moyenne", [
            ("histogram_quantile(0.95, sum by (le) (rate(artelio_lot_duree_secondes_bucket[5m])))", "durée p95 (s)"),
            ("sum(rate(artelio_lot_taille_sum[5m])) / sum(rate(artelio_lot_taille_count[5m]))", "taille moyenne")], w=8),
    ])

    g.row("Traitements planifiés (Airflow) et qualité des données")
    g.line([
        stat("Dernier chargement de l'entrepôt", "time() - artelio_dwh_dernier_chargement_timestamp_seconds", w=6, unit="s",
             thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 1800}, {"color": "red", "value": 7200}],
             desc="DAG artelio_dwh_incremental, toutes les 15 minutes."),
        stat("Règles qualité conformes", "count(artelio_qualite_regle_ok == 1) / count(artelio_qualite_regle_ok)", w=6,
             unit="percentunit", thresholds=[{"color": "red", "value": None}, {"color": "orange", "value": 0.8}, {"color": "green", "value": 1}]),
        stat("Opérations suspectes (audit)", "max(artelio_anomalies_audit) or vector(0)", w=6,
             thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
             desc="Modifications ou suppressions massives hors DPO : déclenche la procédure de violation."),
        stat("Dernier échec Airflow", "max(artelio_dag_dernier_echec_timestamp_seconds) * 1000", w=6, unit="dateTimeFromNow",
             thresholds=[{"color": "orange", "value": None}], no_value="Aucun échec",
             desc="Dernier échec définitif d'une tâche (après 3 tentatives automatiques)."),
    ], height=5)
    g.line([
        {
            "type": "bargauge", "title": "Taux de conformité par règle (plan de gouvernance §6)", "w": 12, "datasource": PROM,
            "targets": [prom_target("artelio_qualite_taux_conformite", "{{regle}}")],
            "options": {"orientation": "horizontal", "displayMode": "gradient", "showUnfilled": True,
                        "reduceOptions": {"calcs": ["lastNotNull"]}},
            "fieldConfig": {"defaults": {"unit": "percentunit", "min": 0.9, "max": 1, "decimals": 2, "thresholds": {
                "mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "orange", "value": 0.98},
                                              {"color": "green", "value": 0.99}]}}, "overrides": []},
        },
        sql_panel("Dernières exécutions (traçabilité)", """
            SELECT to_char(debut, 'DD/MM HH24:MI') AS debut, dag_id, tache, statut, lignes_lues, lignes_ecrites,
                   round(extract(epoch FROM fin - debut)::numeric, 1) AS "durée (s)"
            FROM pipeline.journal_executions ORDER BY id DESC LIMIT 12""", kind="table", w=12),
    ], height=9)
    return dashboard("Pipelines temps réel Artelio", "artelio-pipelines", g.panels, refresh="10s", range_="now-1h",
                     desc="Bloc 3 : débit, latence, rejets, retard Kafka, qualité des données et exécutions Airflow.")


def dashboard(title, uid, panels, refresh, range_, desc):
    return {
        "title": title,
        "uid": uid,
        "description": desc,
        "editable": False,
        "schemaVersion": 39,
        "time": {"from": range_, "to": "now"},
        "refresh": refresh,
        "timezone": "browser",
        "tags": ["artelio"],
        "panels": panels,
    }


if __name__ == "__main__":
    for name, board in (("plateforme.json", plateforme()), ("metier.json", metier()), ("pipelines.json", pipelines())):
        (OUT / name).write_text(json.dumps(board, indent=2, ensure_ascii=False), encoding="utf-8")
        print("écrit :", OUT / name)
