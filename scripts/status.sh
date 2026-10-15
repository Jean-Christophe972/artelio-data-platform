#!/usr/bin/env bash
# Tableau de bord rapide de l'état de la plateforme, en ligne de commande.
set -uo pipefail
PREFIX="${ARTELIO_ENV:-artelio}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Conteneurs :"
docker ps -a --filter "label=com.artelio.project=data-platform" --format '  {{printf "%-30s" .Names}} {{.Status}}' | sort

echo
echo "Contrôles :"
check() { if eval "$2" >/dev/null 2>&1; then printf '  [OK]     %s\n' "$1"; else printf '  [ÉCHEC]  %s\n' "$1"; fi; }
check "PostgreSQL primaire accepte les écritures" \
  "[ \"\$(docker exec ${PREFIX}-pg-primary psql -U artelio_admin -d artelio -Atc 'SELECT NOT pg_is_in_recovery()')\" = t ]"
check "Réplication en flux active (TLS)" \
  "[ \"\$(docker exec ${PREFIX}-pg-primary psql -U artelio_admin -d artelio -Atc \"SELECT count(*) FROM pg_stat_replication r JOIN pg_stat_ssl s USING (pid) WHERE r.state = 'streaming' AND s.ssl\")\" -ge 1 ]"
check "Stockage objet S3 opérationnel" "curl -sf http://localhost:18333/status"
check "Kafka répond" "docker exec ${PREFIX}-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list"
check "Prometheus : toutes les cibles sont joignables" \
  "curl -s localhost:19090/api/v1/targets | python3 -c 'import sys,json; t=json.load(sys.stdin)[\"data\"][\"activeTargets\"]; sys.exit(any(x[\"health\"]!=\"up\" for x in t))'"
check "Sauvegarde réussie depuis moins de 2 h" \
  "curl -s 'localhost:19090/api/v1/query?query=time()-artelio_backup_last_success_timestamp_seconds<7200' | grep -q '\"value\"'"

echo
echo "Interfaces :"
terraform -chdir="${ROOT}/terraform" output -json urls 2>/dev/null | python3 -c 'import sys,json; [print(f"  {k:<13} {v}") for k,v in json.load(sys.stdin).items()]'
echo "  Grafana : utilisateur admin, mot de passe affiché par ./scripts/grafana_password.sh"
