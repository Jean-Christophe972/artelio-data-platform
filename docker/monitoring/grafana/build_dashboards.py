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


def stat(title, expr, w=4, unit="none", thresholds=None, mappings=None, legend="", desc=""):
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
    for name, board in (("plateforme.json", plateforme()), ("metier.json", metier())):
        (OUT / name).write_text(json.dumps(board, indent=2, ensure_ascii=False), encoding="utf-8")
        print("écrit :", OUT / name)
