#!/usr/bin/env bash
# Test de restauration : une sauvegarde n'a de valeur que si on sait la restaurer.
# Télécharge la dernière sauvegarde chiffrée, la déchiffre, la restaure dans un
# PostgreSQL jetable (isolé sur le réseau interne), compare les volumes, puis supprime tout.
set -euo pipefail

PREFIX="${ARTELIO_ENV:-artelio}"
TEST="${PREFIX}-restore-test"
DUMP=$(mktemp)
trap 'rm -f "${DUMP}"; docker rm -f "${TEST}" >/dev/null 2>&1 || true' EXIT

echo "▶ 1. Téléchargement et déchiffrement de la dernière sauvegarde"
docker exec "${PREFIX}-backup" /usr/local/bin/fetch_latest.sh > "${DUMP}"
echo "   Taille déchiffrée : $(wc -c < "${DUMP}" | tr -d ' ') octets"

echo "▶ 2. Démarrage d'un PostgreSQL jetable"
docker run -d --name "${TEST}" --network "${PREFIX}-backend" \
  -e POSTGRES_PASSWORD=restore-test -e POSTGRES_DB=restauration postgres:16.10 >/dev/null
until docker exec "${TEST}" pg_isready -U postgres -q; do sleep 1; done
sleep 2

echo "▶ 3. Restauration"
start=$(date +%s)
docker cp "${DUMP}" "${TEST}:/tmp/artelio.dump"
docker exec "${TEST}" pg_restore -U postgres -d restauration --no-owner --no-privileges /tmp/artelio.dump 2>&1 \
  | grep -v "role .* does not exist" || true
echo "   Restauration terminée en $(( $(date +%s) - start )) s (objectif de reprise : 8 h)"

echo "▶ 4. Vérification : comparaison production / restauration"
printf '   %-22s %12s %12s\n' "table" "production" "restaurée"
for t in clients artisans demandes messages devis factures; do
  prod=$(docker exec "${PREFIX}-pg-replica" psql -U artelio_admin -d artelio -Atc "SELECT count(*) FROM app.${t}")
  rest=$(docker exec "${TEST}" psql -U postgres -d restauration -Atc "SELECT count(*) FROM app.${t}")
  printf '   %-22s %12s %12s\n' "app.${t}" "${prod}" "${rest}"
done
echo "   (de petits écarts sont normaux : la production a pu évoluer depuis la sauvegarde)"
echo "▶ 5. Nettoyage : le PostgreSQL jetable et le fichier déchiffré sont supprimés"
