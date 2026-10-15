#!/bin/bash
# Paramètres communs au primaire et au réplica PostgreSQL.
# Sourcé par entrypoint-primary.sh et entrypoint-replica.sh.

CERT_DIR=/var/lib/postgresql/certs

# PG_ARGS est utilisé par les scripts qui sourcent ce fichier
# shellcheck disable=SC2034
PG_ARGS=(
  # --- Chiffrement en transit : TLS obligatoire pour toute connexion réseau ---
  -c ssl=on
  -c ssl_cert_file="${CERT_DIR}/server.crt"
  -c ssl_key_file="${CERT_DIR}/server.key"
  -c ssl_ca_file="${CERT_DIR}/ca.crt"
  -c ssl_min_protocol_version=TLSv1.2
  -c hba_file=/etc/artelio/pg_hba.conf
  -c password_encryption=scram-sha-256

  # --- Réplication en flux vers le réplica (continuité de service) ---
  -c wal_level=replica
  -c max_wal_senders=10
  -c max_replication_slots=10
  -c wal_keep_size=512MB
  -c hot_standby=on

  # --- Observabilité : journal des connexions et des requêtes lentes ---
  -c shared_preload_libraries=pg_stat_statements
  -c log_connections=on
  -c log_disconnections=on
  -c "log_line_prefix=%m [%p] %u@%d "
  -c log_min_duration_statement=500

  # --- Dimensionnement (cf. docs/CAHIER_DES_CHARGES.md) ---
  -c max_connections=200
  -c shared_buffers=256MB
)

# Terraform dépose les certificats en lecture seule pour root.
# PostgreSQL refuse une clé privée qui ne lui appartient pas en 0600 : on la recopie.
install_certs() {
  install -d -o postgres -g postgres -m 700 "${CERT_DIR}"
  install -o postgres -g postgres -m 600 /etc/artelio/certs/server.key "${CERT_DIR}/server.key"
  install -o postgres -g postgres -m 644 /etc/artelio/certs/server.crt "${CERT_DIR}/server.crt"
  install -o postgres -g postgres -m 644 /etc/artelio/certs/ca.crt "${CERT_DIR}/ca.crt"
}
