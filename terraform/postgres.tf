# -----------------------------------------------------------------------------
# PostgreSQL : base transactionnelle (schéma app) + entrepôt en étoile (schéma dwh)
#   - pg-primary : lecture/écriture
#   - pg-replica : copie en continu (réplication en flux), lecture seule,
#                  promouvable en cas de panne du primaire (scripts/failover_demo.sh)
# -----------------------------------------------------------------------------

locals {
  pg_dir      = "${local.docker}/postgres"
  pg_initdb   = fileset("${local.pg_dir}/initdb", "*.{sql,sh}")
  pg_scripts  = ["common.sh", "entrypoint-primary.sh", "entrypoint-replica.sh", "pg_hba.conf"]
  pg_database = "artelio"

  pg_certs = {
    "server.crt" = tls_locally_signed_cert.postgres.cert_pem
    "server.key" = tls_private_key.postgres.private_key_pem
    "ca.crt"     = tls_self_signed_cert.ca.cert_pem
  }

  pg_primary_env = [
    "POSTGRES_USER=artelio_admin",
    "POSTGRES_PASSWORD=${random_password.db["admin"].result}",
    "POSTGRES_DB=${local.pg_database}",
    "POSTGRES_INITDB_ARGS=--data-checksums --locale=C.UTF-8",
    "REPLICATION_PASSWORD=${random_password.db["replicator"].result}",
    "APP_API_PASSWORD=${random_password.db["app_api"].result}",
    "PIPELINE_ETL_PASSWORD=${random_password.db["pipeline_etl"].result}",
    "ANALYST_PASSWORD=${random_password.db["analyst"].result}",
    "DPO_OFFICER_PASSWORD=${random_password.db["dpo_officer"].result}",
    "MONITORING_PASSWORD=${random_password.db["monitoring"].result}",
    "BACKUP_PASSWORD=${random_password.db["backup"].result}",
    "ML_SERVICE_PASSWORD=${random_password.db["ml_service"].result}",
    "COLUMN_ENCRYPTION_KEY=${random_password.column_encryption_key.result}",
    "PSEUDONYMISATION_KEY=${random_password.pseudonymisation_key.result}",
  ]
}

resource "docker_image" "postgres" {
  name         = var.images["postgres"]
  keep_locally = true
}

resource "docker_volume" "pg_primary" {
  name = "${local.prefix}-pg-primary-data"
}

resource "docker_volume" "pg_replica" {
  name = "${local.prefix}-pg-replica-data"
}

resource "docker_container" "pg_primary" {
  name         = "${local.prefix}-pg-primary"
  hostname     = "pg-primary"
  image        = docker_image.postgres.image_id
  restart      = "unless-stopped"
  entrypoint   = ["/bin/bash", "/etc/artelio/entrypoint-primary.sh"]
  env          = local.pg_primary_env
  shm_size     = 256
  wait         = true # Terraform attend que le healthcheck soit vert avant de créer le réplica
  wait_timeout = 180

  networks_advanced {
    name    = docker_network.backend.id
    aliases = ["pg-primary"]
  }
  networks_advanced {
    name = docker_network.edge.id
  }

  ports {
    internal = 5432
    external = var.ports.postgres_primary
    ip       = var.bind_address
  }

  volumes {
    volume_name    = docker_volume.pg_primary.name
    container_path = "/var/lib/postgresql/data"
  }

  dynamic "upload" {
    for_each = local.pg_initdb
    content {
      file        = "/docker-entrypoint-initdb.d/${upload.value}"
      source      = "${local.pg_dir}/initdb/${upload.value}"
      source_hash = filesha256("${local.pg_dir}/initdb/${upload.value}")
      executable  = endswith(upload.value, ".sh")
    }
  }

  dynamic "upload" {
    for_each = toset(local.pg_scripts)
    content {
      file        = "/etc/artelio/${upload.value}"
      source      = "${local.pg_dir}/scripts/${upload.value}"
      source_hash = filesha256("${local.pg_dir}/scripts/${upload.value}")
    }
  }

  dynamic "upload" {
    for_each = local.pg_certs
    content {
      file    = "/etc/artelio/certs/${upload.key}"
      content = upload.value
    }
  }

  healthcheck {
    test         = ["CMD-SHELL", "pg_isready -U artelio_admin -d ${local.pg_database} -h 127.0.0.1"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 6
    start_period = "30s"
  }

  dynamic "labels" {
    for_each = merge(local.common_labels, { "com.artelio.component" = "postgres-primary" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_container" "pg_replica" {
  name         = "${local.prefix}-pg-replica"
  hostname     = "pg-replica"
  image        = docker_image.postgres.image_id
  restart      = "unless-stopped"
  entrypoint   = ["/bin/bash", "/etc/artelio/entrypoint-replica.sh"]
  env          = ["REPLICATION_PASSWORD=${random_password.db["replicator"].result}"]
  shm_size     = 256
  wait         = true
  wait_timeout = 240

  networks_advanced {
    name    = docker_network.backend.id
    aliases = ["pg-replica"]
  }
  networks_advanced {
    name = docker_network.edge.id
  }

  ports {
    internal = 5432
    external = var.ports.postgres_replica
    ip       = var.bind_address
  }

  volumes {
    volume_name    = docker_volume.pg_replica.name
    container_path = "/var/lib/postgresql/data"
  }

  dynamic "upload" {
    for_each = toset(local.pg_scripts)
    content {
      file        = "/etc/artelio/${upload.value}"
      source      = "${local.pg_dir}/scripts/${upload.value}"
      source_hash = filesha256("${local.pg_dir}/scripts/${upload.value}")
    }
  }

  dynamic "upload" {
    for_each = local.pg_certs
    content {
      file    = "/etc/artelio/certs/${upload.key}"
      content = upload.value
    }
  }

  healthcheck {
    test         = ["CMD-SHELL", "pg_isready -U artelio_admin -d ${local.pg_database} -h 127.0.0.1"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 12
    start_period = "60s"
  }

  dynamic "labels" {
    for_each = merge(local.common_labels, { "com.artelio.component" = "postgres-replica" })
    content {
      label = labels.key
      value = labels.value
    }
  }

  depends_on = [docker_container.pg_primary]
}

# --- Exporteurs Prometheus (un par instance) ---------------------------------

resource "docker_image" "postgres_exporter" {
  name         = var.images["postgres_exporter"]
  keep_locally = true
}

resource "docker_container" "pg_exporter" {
  for_each = {
    primary = "pg-primary"
    replica = "pg-replica"
  }

  name    = "${local.prefix}-pg-exporter-${each.key}"
  image   = docker_image.postgres_exporter.image_id
  restart = "unless-stopped"
  env = [
    "DATA_SOURCE_URI=${each.value}:5432/${local.pg_database}?sslmode=require",
    "DATA_SOURCE_USER=monitoring",
    "DATA_SOURCE_PASS=${random_password.db["monitoring"].result}",
  ]

  networks_advanced {
    name    = docker_network.backend.id
    aliases = ["pg-exporter-${each.key}"]
  }

  dynamic "labels" {
    for_each = merge(local.common_labels, { "com.artelio.component" = "monitoring" })
    content {
      label = labels.key
      value = labels.value
    }
  }

  depends_on = [docker_container.pg_replica]
}
