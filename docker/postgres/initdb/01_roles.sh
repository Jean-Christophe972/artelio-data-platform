#!/bin/bash
# Rôles PostgreSQL : un compte par usage (principe du moindre privilège).
# Les mots de passe sont générés par Terraform et transmis en variables d'environnement.
# Les droits précis sur les tables sont donnés dans 06_grants.sql.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  -- Réplication physique vers le réplica
  CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD '${REPLICATION_PASSWORD}';

  -- API applicative : lit et écrit les données métier, rien d'autre
  CREATE ROLE app_api WITH LOGIN CONNECTION LIMIT 100 PASSWORD '${APP_API_PASSWORD}';

  -- Pipelines de données (bloc 3) : lit le métier, alimente l'entrepôt pseudonymisé
  CREATE ROLE pipeline_etl WITH LOGIN CONNECTION LIMIT 20 PASSWORD '${PIPELINE_ETL_PASSWORD}';

  -- Analystes : lecture seule de l'entrepôt pseudonymisé, aucun accès aux données identifiantes
  CREATE ROLE analyst WITH LOGIN CONNECTION LIMIT 10 PASSWORD '${ANALYST_PASSWORD}';

  -- DPO : exécute les fonctions RGPD (export, effacement, purge) et lit le journal d'audit
  CREATE ROLE dpo_officer WITH LOGIN CONNECTION LIMIT 5 PASSWORD '${DPO_OFFICER_PASSWORD}';

  -- Service IA (bloc 4) : qualification des demandes, journal des prédictions (droits : 07_ml.sql)
  CREATE ROLE ml_service WITH LOGIN CONNECTION LIMIT 20 PASSWORD '${ML_SERVICE_PASSWORD}';

  -- Supervision (Prometheus) : statistiques uniquement, aucune donnée métier
  CREATE ROLE monitoring WITH LOGIN CONNECTION LIMIT 5 PASSWORD '${MONITORING_PASSWORD}' IN ROLE pg_monitor;

  -- Sauvegardes : lecture seule de toutes les données
  CREATE ROLE backup_agent WITH LOGIN CONNECTION LIMIT 2 PASSWORD '${BACKUP_PASSWORD}' IN ROLE pg_read_all_data;

  -- Clés applicatives attachées aux rôles qui en ont besoin.
  -- En production, elles viendraient d'un gestionnaire de secrets (KMS / Vault).
  ALTER ROLE app_api      SET artelio.cle_chiffrement = '${COLUMN_ENCRYPTION_KEY}';
  ALTER ROLE dpo_officer  SET artelio.cle_chiffrement = '${COLUMN_ENCRYPTION_KEY}';
  ALTER ROLE pipeline_etl SET artelio.cle_pseudonymisation = '${PSEUDONYMISATION_KEY}';

  -- Personne ne se connecte ni ne crée d'objet par défaut
  REVOKE ALL ON DATABASE ${POSTGRES_DB} FROM PUBLIC;
  REVOKE CREATE ON SCHEMA public FROM PUBLIC;
  GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO app_api, pipeline_etl, analyst, dpo_officer, monitoring, backup_agent, ml_service;
EOSQL
