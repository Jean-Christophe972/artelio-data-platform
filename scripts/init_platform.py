"""Initialisation idempotente de la plateforme : buckets S3 et topics Kafka.

Lancé automatiquement par Terraform (ressource docker_container.platform_init).
Peut être relancé sans risque : ce qui existe déjà est conservé.
"""

from __future__ import annotations

import json
import os
import sys

from botocore.exceptions import ClientError
from confluent_kafka.admin import AdminClient, NewTopic

from platform_common import get_logger, require_env, retry, s3_client

log = get_logger("init")

# photos : pièces jointes des demandes ; factures : PDF (10 ans) ; backups : sauvegardes chiffrées ;
# datasets : jeux d'entraînement IA pseudonymisés et versionnés (bloc 3 → bloc 4)
BUCKETS = ["photos", "factures", "backups", "datasets"]


def create_buckets() -> None:
    s3 = s3_client("S3_ADMIN_ACCESS_KEY", "S3_ADMIN_SECRET_KEY")
    existing = retry(lambda: {b["Name"] for b in s3.list_buckets().get("Buckets", [])}, "Stockage objet")
    for bucket in BUCKETS:
        if bucket in existing:
            log.info("Bucket '%s' déjà présent", bucket)
            continue
        try:
            s3.create_bucket(Bucket=bucket)
            log.info("Bucket '%s' créé", bucket)
        except ClientError as exc:
            if exc.response["Error"]["Code"] not in ("BucketAlreadyExists", "BucketAlreadyOwnedByYou"):
                raise


def create_topics() -> None:
    topics: dict[str, int] = json.loads(require_env("KAFKA_TOPICS"))
    admin = AdminClient({"bootstrap.servers": require_env("KAFKA_BOOTSTRAP")})
    existing = retry(lambda: set(admin.list_topics(timeout=5).topics), "Kafka")

    to_create = [
        NewTopic(
            name,
            num_partitions=partitions,
            replication_factor=int(os.environ.get("KAFKA_REPLICATION_FACTOR", "1")),
            # Rétention 7 jours ; la file des erreurs (DLQ) est gardée 30 jours pour analyse
            config={"retention.ms": str((30 if name.startswith("dlq") else 7) * 24 * 3600 * 1000)},
        )
        for name, partitions in topics.items()
        if name not in existing
    ]
    for name in sorted(set(topics) & existing):
        log.info("Topic '%s' déjà présent", name)
    if not to_create:
        return
    for name, future in admin.create_topics(to_create).items():
        future.result()  # lève une exception si la création échoue
        log.info("Topic '%s' créé (%s partitions)", name, topics[name])


def main() -> int:
    try:
        create_buckets()
        create_topics()
    except Exception:  # noqa: BLE001 — on journalise toute erreur puis on renvoie un code d'échec
        log.exception("Échec de l'initialisation de la plateforme")
        return 1
    log.info("Plateforme initialisée")
    return 0


if __name__ == "__main__":
    sys.exit(main())
