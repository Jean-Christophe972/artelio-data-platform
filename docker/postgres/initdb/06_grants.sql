-- =============================================================================
-- Droits d'accès : matrice "qui accède à quoi" (plan de gouvernance §7)
--
--               | app (métier)        | besoins_access. | dwh (pseudonymisé) | audit   | rgpd
-- app_api       | lecture/écriture    | oui             | -                  | -       | -
-- pipeline_etl  | lecture             | NON             | lecture/écriture   | -       | purge
-- analyst       | -                   | -               | lecture            | -       | -
-- dpo_officer   | -                   | -               | -                  | lecture | export, effacement, purge
-- ml_service    | demandes (colonnes utiles) | NON  | -                  | -       | -     (+ schéma ml)
-- monitoring    | statistiques uniquement (pg_monitor)
-- backup_agent  | lecture de tout (pg_read_all_data) pour les sauvegardes
-- =============================================================================

-- API applicative
GRANT USAGE ON SCHEMA app TO app_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app TO app_api;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA app TO app_api;
REVOKE UPDATE, DELETE ON app.consentements FROM app_api;   -- historique de preuve
REVOKE UPDATE, DELETE ON app.factures FROM app_api;        -- pièce comptable

-- Pipelines (bloc 3) : jamais d'accès à la donnée de santé
GRANT USAGE ON SCHEMA app TO pipeline_etl;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO pipeline_etl;
REVOKE SELECT ON app.besoins_accessibilite FROM pipeline_etl;
GRANT INSERT ON app.positions_artisans, app.demandes, app.messages TO pipeline_etl;
GRANT UPDATE (metier_predit, urgence_predite, confiance_ia, statut) ON app.demandes TO pipeline_etl;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA app TO pipeline_etl;
GRANT USAGE, CREATE ON SCHEMA dwh TO pipeline_etl;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA dwh TO pipeline_etl;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA dwh TO pipeline_etl;
GRANT EXECUTE ON PROCEDURE dwh.rafraichir_entrepot() TO pipeline_etl;

GRANT UPDATE (statut, debut_reel, fin_reelle) ON app.interventions TO pipeline_etl;
GRANT EXECUTE ON FUNCTION audit.detecter_anomalies(interval, integer) TO pipeline_etl;
GRANT USAGE ON SCHEMA audit TO pipeline_etl;

-- Schéma propre aux pipelines (traçabilité des exécutions, résultats des contrôles qualité) :
-- le bloc 3 y crée ses tables avec ses propres migrations
CREATE SCHEMA pipeline AUTHORIZATION pipeline_etl;
GRANT USAGE ON SCHEMA pipeline TO dpo_officer, analyst;

-- Analystes : entrepôt uniquement
GRANT USAGE ON SCHEMA dwh TO analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA dwh TO analyst;

-- DPO : passe obligatoirement par les fonctions RGPD (tracées), pas d'accès direct aux tables
GRANT USAGE ON SCHEMA rgpd, audit TO dpo_officer;
GRANT EXECUTE ON FUNCTION rgpd.exporter_client(uuid), rgpd.effacer_client(uuid, text),
                          rgpd.purger_donnees_expirees() TO dpo_officer;
GRANT SELECT ON rgpd.registre_demandes, audit.journal TO dpo_officer;

-- La purge automatique est aussi lancée par l'orchestrateur
GRANT USAGE ON SCHEMA rgpd TO pipeline_etl;
GRANT EXECUTE ON FUNCTION rgpd.purger_donnees_expirees() TO pipeline_etl;

-- Créneau de réplication réservé au réplica : le primaire conserve les WAL tant que le réplica ne les a pas lus
SELECT pg_create_physical_replication_slot('replica_1');
