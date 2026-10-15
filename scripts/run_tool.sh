#!/usr/bin/env bash
# Lance un script Python de /scripts dans l'image "outils", sur le réseau interne.
# Les secrets sont repris du conteneur d'initialisation créé par Terraform :
# ils ne sont jamais écrits sur le disque ni affichés.
#
#   ./scripts/run_tool.sh seed_data.py --demandes 8000
set -euo pipefail

PREFIX="${ARTELIO_ENV:-artelio}"
SCRIPT="${1:?Usage : run_tool.sh <script.py> [arguments]}"
shift

ENV_FILE=$(mktemp)
trap 'rm -f "${ENV_FILE}"' EXIT
docker inspect "${PREFIX}-platform-init" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -E '^(PG_|S3_|KAFKA_)' > "${ENV_FILE}"

docker run --rm -i \
  --network "${PREFIX}-backend" \
  --env-file "${ENV_FILE}" \
  "${PREFIX}-tools:latest" \
  python "scripts/${SCRIPT}" "$@"
