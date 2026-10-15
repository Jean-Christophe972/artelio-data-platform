#!/bin/bash
# Télécharge et déchiffre la dernière sauvegarde, écrite sur la sortie standard.
# Utilisé par scripts/restore_test.sh pour vérifier qu'une sauvegarde est restaurable.
set -euo pipefail
key=$(python3 /usr/local/bin/s3_tool.py latest "postgres/")
python3 /usr/local/bin/s3_tool.py download "${key}" /tmp/latest.dump.enc >&2
echo "[restore] Sauvegarde téléchargée : ${key}" >&2
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:BACKUP_ENCRYPTION_KEY -in /tmp/latest.dump.enc
rm -f /tmp/latest.dump.enc
