#!/bin/bash
# Point d'entrée du réplica PostgreSQL (lecture seule, "hot standby").
# Au premier démarrage, il clone le primaire (pg_basebackup) puis suit son journal (WAL)
# en continu. En cas de panne du primaire, il peut être promu : scripts/failover_demo.sh
set -euo pipefail
# shellcheck source=common.sh
source /etc/artelio/common.sh

install_certs

if [ ! -s "${PGDATA}/PG_VERSION" ]; then
  echo "[replica] Attente du primaire pg-primary..."
  until pg_isready -h pg-primary -p 5432 -U replicator -q; do sleep 2; done

  echo "[replica] Clonage initial du primaire (TLS vérifié)..."
  install -d -o postgres -g postgres -m 700 "${PGDATA}"
  gosu postgres pg_basebackup \
    -d "host=pg-primary port=5432 user=replicator password=${REPLICATION_PASSWORD} sslmode=verify-full sslrootcert=${CERT_DIR}/ca.crt" \
    -D "${PGDATA}" \
    --wal-method=stream \
    --slot=replica_1 \
    --write-recovery-conf \
    --checkpoint=fast
  echo "[replica] Clonage terminé, démarrage en lecture seule."
fi

exec gosu postgres postgres "${PG_ARGS[@]}"
