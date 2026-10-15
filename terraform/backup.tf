# -----------------------------------------------------------------------------
# Agent de sauvegarde : dump PostgreSQL chiffré (AES-256) → bucket S3 "backups"
# RPO 1 h (variable backup_interval_seconds), rétention 30 jours.
# Restauration testée par scripts/restore_test.sh (plan de gouvernance : test mensuel).
# -----------------------------------------------------------------------------

locals {
  backup_dir     = "${local.docker}/backup"
  backup_sources = ["Dockerfile", "backup.sh", "fetch_latest.sh", "s3_tool.py"]
}

resource "docker_image" "backup" {
  name = "${local.prefix}-backup:latest"

  build {
    context = local.backup_dir
  }

  triggers = {
    sources = sha256(join("", [for f in local.backup_sources : filesha256("${local.backup_dir}/${f}")]))
  }

  depends_on = [docker_image.postgres]
}

resource "docker_container" "backup" {
  name    = "${local.prefix}-backup"
  image   = docker_image.backup.image_id
  restart = "unless-stopped"

  env = [
    "BACKUP_DB_PASSWORD=${random_password.db["backup"].result}",
    "BACKUP_ENCRYPTION_KEY=${random_password.backup_encryption_key.result}",
    "BACKUP_INTERVAL_SECONDS=${var.backup_interval_seconds}",
    "BACKUP_RETENTION_DAYS=${var.backup_retention_days}",
    "S3_ENDPOINT=http://object-storage:8333",
    "S3_ACCESS_KEY=${random_password.s3_access["backup"].result}",
    "S3_SECRET_KEY=${random_password.s3_secret["backup"].result}",
  ]

  networks_advanced {
    name = docker_network.backend.id
  }

  dynamic "labels" {
    for_each = merge(local.common_labels, { "com.artelio.component" = "backup" })
    content {
      label = labels.key
      value = labels.value
    }
  }

  depends_on = [docker_container.platform_init, docker_container.pushgateway]
}
