"""Fonctions partagées par les scripts Python de la plateforme Artelio.

Toutes les informations de connexion viennent de variables d'environnement
injectées par Terraform (aucun secret dans le code).
"""

from __future__ import annotations

import logging
import os
import time
from collections.abc import Callable

import boto3
import psycopg
from botocore.config import Config

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)-7s %(name)s — %(message)s",
)


def get_logger(name: str) -> logging.Logger:
    return logging.getLogger(name)


def require_env(name: str) -> str:
    """Lit une variable d'environnement obligatoire, avec un message clair si elle manque."""
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Variable d'environnement manquante : {name}")
    return value


def retry[T](action: Callable[[], T], what: str, attempts: int = 30, delay: float = 2.0) -> T:
    """Réessaie une action (ex. connexion à un service qui démarre) avant d'abandonner."""
    log = get_logger("retry")
    for attempt in range(1, attempts + 1):
        try:
            return action()
        except Exception as exc:  # noqa: BLE001 — on veut réessayer quelle que soit l'erreur réseau
            if attempt == attempts:
                raise RuntimeError(f"{what} indisponible après {attempts} tentatives") from exc
            log.warning("%s pas encore prêt (%s/%s) : %s", what, attempt, attempts, exc)
            time.sleep(delay)
    raise AssertionError("inatteignable")


def pg_connect(user: str, password_env: str, autocommit: bool = False) -> psycopg.Connection:
    """Connexion PostgreSQL en TLS obligatoire (sslmode=require)."""
    return psycopg.connect(
        host=require_env("PG_HOST"),
        port=int(os.environ.get("PG_PORT", "5432")),
        dbname=require_env("PG_DATABASE"),
        user=user,
        password=require_env(password_env),
        sslmode="require",
        autocommit=autocommit,
        connect_timeout=5,
    )


def s3_client(access_env: str, secret_env: str):
    """Client S3 vers le stockage objet SeaweedFS."""
    return boto3.client(
        "s3",
        endpoint_url=require_env("S3_ENDPOINT"),
        aws_access_key_id=require_env(access_env),
        aws_secret_access_key=require_env(secret_env),
        region_name="eu-west-3",
        config=Config(retries={"max_attempts": 5, "mode": "standard"}, s3={"addressing_style": "path"}),
    )
