#!/bin/bash
# Point d'entrée du PostgreSQL primaire (lecture/écriture).
# Au premier démarrage, l'image officielle exécute docker/postgres/initdb/* (schémas, rôles, RGPD).
set -euo pipefail
# shellcheck source=common.sh
source /etc/artelio/common.sh

install_certs
exec docker-entrypoint.sh postgres "${PG_ARGS[@]}"
