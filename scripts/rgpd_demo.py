"""Démonstration des mécanismes RGPD et du contrôle d'accès de la plateforme.

    ./scripts/run_tool.sh rgpd_demo.py [--client <uuid>]

1. Moindre privilège : l'analyste ne voit pas les données identifiantes, le pipeline
   ne voit pas les données de santé.
2. Droit d'accès / portabilité : export JSON complet d'un client (rgpd.exporter_client).
3. Droit à l'effacement : rgpd.effacer_client, puis suppression des photos dans S3.
   Les factures sont conservées (obligation légale de 10 ans).
4. Durées de conservation : rgpd.purger_donnees_expirees.
5. Traçabilité : registre des demandes RGPD et journal d'audit.
"""

from __future__ import annotations

import argparse
import json
import sys

import psycopg

from platform_common import get_logger, pg_connect, s3_client

log = get_logger("rgpd")


def titre(texte: str) -> None:
    print(f"\n{'=' * 78}\n{texte}\n{'=' * 78}")


def verifier_moindre_privilege() -> None:
    titre("1. Moindre privilège : chaque compte ne voit que ce dont il a besoin")
    essais = [
        ("pipeline_etl", "PG_ETL_PASSWORD", "SELECT count(*) FROM app.besoins_accessibilite", "données de santé"),
        ("pipeline_etl", "PG_ETL_PASSWORD", "SELECT count(*) FROM dwh.fait_demande", "entrepôt pseudonymisé"),
        ("dpo_officer", "PG_DPO_PASSWORD", "SELECT count(*) FROM app.clients", "lecture directe des clients"),
    ]
    for user, pwd_env, sql, quoi in essais:
        try:
            with pg_connect(user, pwd_env) as conn:
                n = conn.execute(sql).fetchone()[0]
            print(f"  [AUTORISÉ] {user:<13} → {quoi:<30} ({n} lignes)")
        except psycopg.errors.InsufficientPrivilege:
            print(f"  [REFUSÉ]   {user:<13} → {quoi:<30} (permission denied)")


def choisir_client(conn: psycopg.Connection) -> str:
    """Un client actif qui a au moins une facture et des photos : le cas le plus complet."""
    row = conn.execute("""
        SELECT d.client_id FROM app.demandes d
        JOIN app.photos_demande p ON p.demande_id = d.id
        JOIN app.devis v ON v.demande_id = d.id
        JOIN app.interventions i ON i.devis_id = v.id
        JOIN app.factures f ON f.intervention_id = i.id
        JOIN app.clients c ON c.id = d.client_id AND c.statut = 'actif'
        LIMIT 1""").fetchone()
    if row is None:
        row = conn.execute("SELECT id FROM app.clients WHERE statut = 'actif' LIMIT 1").fetchone()
    return str(row[0])


def demo(client_id: str | None) -> None:
    verifier_moindre_privilege()

    with pg_connect("artelio_admin", "PG_ADMIN_PASSWORD") as admin:
        client_id = client_id or choisir_client(admin)

    with pg_connect("dpo_officer", "PG_DPO_PASSWORD", autocommit=True) as dpo:
        titre(f"2. Droit d'accès et de portabilité — client {client_id}")
        export = dpo.execute("SELECT rgpd.exporter_client(%s)", (client_id,)).fetchone()[0]
        c = export["client"]
        print(f"  Client         : {c['prenom']} {c['nom']} <{c['email']}>")
        print(f"  Logements      : {len(export['logements'])}")
        print(
            f"  Demandes       : {len(export['demandes'])} "
            f"(messages : {sum(len(d['messages']) for d in export['demandes'])}, "
            f"photos : {sum(len(d['photos']) for d in export['demandes'])})"
        )
        print(f"  Factures       : {len(export['factures'])}")
        print(f"  Consentements  : {len(export['consentements'])}")
        print(f"  Export JSON    : {len(json.dumps(export, default=str))} octets (format {export['format']})")

        titre("3. Droit à l'effacement")
        resultat = dpo.execute("SELECT rgpd.effacer_client(%s)", (client_id,)).fetchone()[0]
        for cle, valeur in resultat.items():
            if cle != "photos_a_supprimer":
                print(f"  {cle:<40} {valeur}")
        photos = resultat["photos_a_supprimer"]
        s3 = s3_client("S3_APP_ACCESS_KEY", "S3_APP_SECRET_KEY")
        for cle in photos:
            s3.delete_object(Bucket="photos", Key=cle)
        print(f"  {'photos supprimées du stockage objet':<40} {len(photos)}")

        apres = dpo.execute("SELECT rgpd.exporter_client(%s)", (client_id,)).fetchone()[0]["client"]
        print(f"  Après effacement → email : {apres['email']}, nom : {apres['nom']}, statut : {apres['statut']}")

        titre("4. Purge automatique des données expirées (durées de conservation)")
        purge = dpo.execute("SELECT rgpd.purger_donnees_expirees()").fetchone()[0]
        for cle, valeur in purge.items():
            if cle != "photos_a_supprimer":
                print(f"  {cle:<40} {valeur}")
        for cle in purge["photos_a_supprimer"]:
            s3.delete_object(Bucket="photos", Key=cle)
        print(f"  {'photos expirées supprimées':<40} {len(purge['photos_a_supprimer'])}")

        titre("5. Traçabilité : registre RGPD et journal d'audit")
        for row in dpo.execute("""SELECT to_char(traitee_le, 'YYYY-MM-DD HH24:MI:SS'), type_demande, traitee_par,
                                         left(client_id::text, 8)
                                  FROM rgpd.registre_demandes ORDER BY id DESC LIMIT 8"""):
            print(f"  registre : {row[0]}  {row[1]:<18} par {row[2]:<12} client {row[3]}…")
        for row in dpo.execute("""SELECT utilisateur, operation, table_cible, count(*)
                                  FROM audit.journal WHERE horodatage > now() - interval '5 minutes'
                                  GROUP BY 1, 2, 3 ORDER BY 4 DESC LIMIT 8"""):
            print(f"  audit    : {row[0]:<12} {row[1]:<7} {row[2]:<26} {row[3]} ligne(s)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--client", help="identifiant du client à traiter (par défaut : choisi automatiquement)")
    args = parser.parse_args()
    try:
        demo(args.client)
    except Exception:  # noqa: BLE001
        log.exception("Échec de la démonstration RGPD")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
