# -----------------------------------------------------------------------------
# Secrets et certificats générés par Terraform.
# Aucun mot de passe n'est écrit dans le dépôt. Ils sont stockés dans l'état
# Terraform (terraform.tfstate), qui est exclu de Git et doit être protégé
# (en production : backend distant chiffré + gestionnaire de secrets).
# -----------------------------------------------------------------------------

locals {
  # Un compte par usage = principe du moindre privilège (voir docker/postgres/initdb)
  db_accounts = ["admin", "replicator", "app_api", "pipeline_etl", "analyst", "dpo_officer", "monitoring", "backup", "ml_service"]
  s3_accounts = ["admin", "app", "backup", "pipeline", "ml"]
}

resource "random_password" "db" {
  for_each = toset(local.db_accounts)
  length   = 32
  special  = false
}

resource "random_password" "s3_secret" {
  for_each = toset(local.s3_accounts)
  length   = 40
  special  = false
}

resource "random_password" "s3_access" {
  for_each = toset(local.s3_accounts)
  length   = 20
  special  = false
  upper    = true
  lower    = false
}

# Clé de chiffrement des sauvegardes (AES-256 via openssl)
resource "random_password" "backup_encryption_key" {
  length  = 48
  special = false
}

# Clé de pseudonymisation (HMAC) utilisée pour alimenter l'entrepôt analytique
resource "random_password" "pseudonymisation_key" {
  length  = 48
  special = false
}

# Clé de chiffrement applicatif des données sensibles (pgcrypto)
resource "random_password" "column_encryption_key" {
  length  = 48
  special = false
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

# --- PKI interne : chiffrement en transit (TLS) entre services ---------------

resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 24 * 365
  allowed_uses          = ["cert_signing", "crl_signing"]

  subject {
    common_name  = "Artelio Internal CA"
    organization = "Artelio SAS"
  }
}

resource "tls_private_key" "postgres" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "postgres" {
  private_key_pem = tls_private_key.postgres.private_key_pem
  dns_names       = ["pg-primary", "pg-replica", "localhost"]
  ip_addresses    = ["127.0.0.1"]

  subject {
    common_name  = "postgres.artelio.internal"
    organization = "Artelio SAS"
  }
}

resource "tls_locally_signed_cert" "postgres" {
  cert_request_pem      = tls_cert_request.postgres.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 24 * 180
  allowed_uses          = ["server_auth", "digital_signature", "key_encipherment"]
}
