#!/usr/bin/env bash
# Déploie toute la plateforme data d'Artelio en une commande.
#   ./scripts/deploy.sh            # déploie (ou met à jour) l'infrastructure
#   ./scripts/deploy.sh --seed     # ... puis charge les données de démonstration
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Fonction plutôt que variable : le chemin peut contenir des espaces
tf() { terraform -chdir="${ROOT}/terraform" "$@"; }

echo "▶ Vérification des prérequis"
command -v docker >/dev/null || { echo "Docker est requis : https://docs.docker.com/get-docker/" >&2; exit 1; }
command -v terraform >/dev/null || { echo "Terraform >= 1.6 est requis : https://developer.hashicorp.com/terraform/install" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Le démon Docker ne répond pas : lancez Docker Desktop." >&2; exit 1; }

echo "▶ Déploiement de l'infrastructure (Terraform)"
tf init -input=false -upgrade >/dev/null
tf apply -auto-approve -input=false

if [[ "${1:-}" == "--seed" ]]; then
  echo "▶ Chargement des données de démonstration"
  "${ROOT}/scripts/run_tool.sh" seed_data.py
fi

echo
"${ROOT}/scripts/status.sh"
