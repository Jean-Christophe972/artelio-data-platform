#!/bin/bash
# Sauvegarde périodique de PostgreSQL (RPO cible : 1 h, cf. plan de gouvernance §11.2)
#   1. pg_dump au format "custom" (compressé, restaurable table par table)
#   2. chiffrement AES-256 (openssl, dérivation de clé PBKDF2)
#   3. envoi dans le bucket S3 "backups", puis suppression des sauvegardes trop anciennes
#   4. publication des métriques vers Prometheus (Pushgateway) : une alerte se déclenche
#      si aucune sauvegarde n'a réussi depuis 2 h (docker/monitoring/alert_rules.yml)
set -uo pipefail

PUSH_URL="http://pushgateway:9091/metrics/job/artelio_backup"

push_metrics() {
  curl -fsS --data-binary @- "${PUSH_URL}" || echo "[backup] Pushgateway injoignable (métriques non publiées)"
}

run_backup() {
  local ts file start size
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  file="/tmp/artelio_${ts}.dump.enc"
  start=$(date +%s)

  echo "[backup] Début de la sauvegarde ${ts}"
  pg_dump "host=pg-primary port=5432 dbname=artelio user=backup_agent sslmode=require" \
      --format=custom --no-owner --no-privileges \
    | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:BACKUP_ENCRYPTION_KEY -out "${file}" \
    || return 1

  size=$(stat -c %s "${file}")
  python3 /usr/local/bin/s3_tool.py upload "${file}" "postgres/artelio_${ts}.dump.enc" || return 1
  python3 /usr/local/bin/s3_tool.py prune "postgres/" "${BACKUP_RETENTION_DAYS}" || return 1
  rm -f "${file}"

  cat <<METRICS | push_metrics
# TYPE artelio_backup_last_success_timestamp_seconds gauge
artelio_backup_last_success_timestamp_seconds $(date +%s)
# TYPE artelio_backup_size_bytes gauge
artelio_backup_size_bytes ${size}
# TYPE artelio_backup_duration_seconds gauge
artelio_backup_duration_seconds $(( $(date +%s) - start ))
METRICS
  echo "[backup] Sauvegarde ${ts} réussie (${size} octets chiffrés)"
}

export PGPASSWORD="${BACKUP_DB_PASSWORD}"
while true; do
  if ! run_backup; then
    echo "[backup] ÉCHEC de la sauvegarde" >&2
    printf '# TYPE artelio_backup_last_failure_timestamp_seconds gauge\nartelio_backup_last_failure_timestamp_seconds %s\n' "$(date +%s)" | push_metrics
    rm -f /tmp/artelio_*.dump.enc
  fi
  sleep "${BACKUP_INTERVAL_SECONDS}"
done
