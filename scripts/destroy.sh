#!/usr/bin/env bash
# Supprime toute la plateforme, Y COMPRIS les données (volumes). Demande confirmation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

read -r -p "Supprimer la plateforme et TOUTES ses données ? Tapez 'supprimer' pour confirmer : " reponse
[[ "${reponse}" == "supprimer" ]] || { echo "Annulé."; exit 0; }
terraform -chdir="${ROOT}/terraform" destroy -auto-approve -input=false
