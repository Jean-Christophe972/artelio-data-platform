#!/usr/bin/env bash
# Affiche le mot de passe administrateur Grafana généré par Terraform (utilisateur : admin).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v terraform >/dev/null || { echo "Terraform est introuvable : installez-le ou ajoutez son dossier au PATH." >&2; exit 1; }
terraform -chdir="${ROOT}/terraform" output -json secrets | python3 -c 'import sys, json; print(json.load(sys.stdin)["grafana_admin"])'
