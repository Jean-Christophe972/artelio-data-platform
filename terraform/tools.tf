# -----------------------------------------------------------------------------
# Image "outils" (Python) : initialisation de la plateforme, données de démonstration,
# démonstrations RGPD. Construite à partir de docker/tools/Dockerfile et de /scripts.
# -----------------------------------------------------------------------------

locals {
  tools_sources = concat(
    [for f in fileset("${local.root_dir}/scripts", "*.py") : "${local.root_dir}/scripts/${f}"],
    ["${local.docker}/tools/Dockerfile", "${local.docker}/tools/requirements.txt"],
  )

  # Variables d'environnement communes aux jobs Python
  tools_env = [
    "PG_HOST=pg-primary",
    "PG_PORT=5432",
    "PG_DATABASE=${local.pg_database}",
    "PG_ADMIN_PASSWORD=${random_password.db["admin"].result}",
    "PG_APP_PASSWORD=${random_password.db["app_api"].result}",
    "PG_DPO_PASSWORD=${random_password.db["dpo_officer"].result}",
    "PG_ETL_PASSWORD=${random_password.db["pipeline_etl"].result}",
    "S3_ENDPOINT=http://object-storage:8333",
    "S3_ADMIN_ACCESS_KEY=${random_password.s3_access["admin"].result}",
    "S3_ADMIN_SECRET_KEY=${random_password.s3_secret["admin"].result}",
    "S3_APP_ACCESS_KEY=${random_password.s3_access["app"].result}",
    "S3_APP_SECRET_KEY=${random_password.s3_secret["app"].result}",
    "KAFKA_BOOTSTRAP=kafka:9092",
    "KAFKA_TOPICS=${jsonencode(var.kafka_topics)}",
  ]
}

resource "docker_image" "tools" {
  name = "${local.prefix}-tools:latest"

  build {
    context    = local.root_dir
    dockerfile = "docker/tools/Dockerfile"
  }

  # Reconstruit l'image quand un script ou une dépendance change
  triggers = {
    sources = sha256(join("", [for f in local.tools_sources : filesha256(f)]))
  }
}

# Job ponctuel : crée les buckets S3 et les topics Kafka (idempotent)
resource "docker_container" "platform_init" {
  name     = "${local.prefix}-platform-init"
  image    = docker_image.tools.image_id
  command  = ["python", "scripts/init_platform.py"]
  env      = local.tools_env
  must_run = false
  attach   = true
  logs     = true

  networks_advanced {
    name = docker_network.backend.id
  }

  depends_on = [docker_container.object_storage, docker_container.kafka, docker_container.pg_primary]
}
