#!/usr/bin/env bash
# Démonstration de continuité de service : panne du PostgreSQL primaire → bascule sur le réplica.
#
#   ./scripts/failover_demo.sh            # simule la panne et promeut le réplica
#   ./scripts/failover_demo.sh --retablir # revient à l'état nominal (primaire + réplica neuf)
#
# En production, la bascule serait automatique (Patroni + etcd) et l'ancien primaire
# rejoindrait le cluster comme réplica via pg_rewind. Ici, on montre le mécanisme pas à pas.
set -euo pipefail

PREFIX="${ARTELIO_ENV:-artelio}"
PRIMARY="${PREFIX}-pg-primary"
REPLICA="${PREFIX}-pg-replica"
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

psql_in() { docker exec "$1" psql -U artelio_admin -d artelio -Atqc "$2"; }
etape() { printf '\n\033[1;34m▶ %s\033[0m\n' "$1"; }

if [[ "${1:-}" == "--retablir" ]]; then
  etape "Retour à l'état nominal : redémarrage du primaire et reconstruction du réplica"
  docker start "${PRIMARY}" >/dev/null
  terraform -chdir="${TF_DIR}" apply -auto-approve -input=false \
    -replace=docker_volume.pg_replica -replace=docker_container.pg_replica >/dev/null
  echo "Réplica en lecture seule : $(psql_in "${REPLICA}" 'SELECT pg_is_in_recovery()')"
  exit 0
fi

etape "1. État initial"
echo "Primaire en lecture seule ? $(psql_in "${PRIMARY}" 'SELECT pg_is_in_recovery()')   (f = accepte les écritures)"
echo "Réplica  en lecture seule ? $(psql_in "${REPLICA}" 'SELECT pg_is_in_recovery()')   (t = copie en lecture seule)"

etape "2. Écriture sur le primaire, lecture sur le réplica (réplication en temps réel)"
psql_in "${PRIMARY}" "CREATE SCHEMA IF NOT EXISTS ops;
  CREATE TABLE IF NOT EXISTS ops.test_bascule (id serial PRIMARY KEY, message text, ecrit_le timestamptz DEFAULT now());
  INSERT INTO ops.test_bascule (message) VALUES ('écrit sur le primaire avant la panne');"
sleep 2
echo "Lu sur le réplica : $(psql_in "${REPLICA}" "SELECT message FROM ops.test_bascule ORDER BY id DESC LIMIT 1")"

etape "3. PANNE : arrêt brutal du primaire"
docker kill "${PRIMARY}" >/dev/null
echo "Conteneur ${PRIMARY} : $(docker inspect -f '{{.State.Status}}' "${PRIMARY}")"
echo "(Prometheus déclenche l'alerte PostgresInjoignable sous 1 minute : http://localhost:19093)"

etape "4. Bascule : promotion du réplica en nouveau primaire"
start=$(date +%s)
psql_in "${REPLICA}" "SELECT pg_promote(wait => true)" >/dev/null
echo "Réplica en lecture seule ? $(psql_in "${REPLICA}" 'SELECT pg_is_in_recovery()')   (f = il accepte maintenant les écritures)"
echo "Durée de la bascule : $(( $(date +%s) - start )) s"

etape "5. Le service continue : écriture sur le nouveau primaire"
psql_in "${REPLICA}" "INSERT INTO ops.test_bascule (message) VALUES ('écrit sur le réplica promu, après la panne')"
psql_in "${REPLICA}" "SELECT id, message, to_char(ecrit_le, 'HH24:MI:SS') FROM ops.test_bascule ORDER BY id"
echo
echo "Aucune donnée perdue : les écritures d'avant la panne sont présentes sur le nouveau primaire."
echo "Pour revenir à l'état nominal : ./scripts/failover_demo.sh --retablir"
