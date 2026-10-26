# -----------------------------------------------------------------------------
# Stockage objet compatible S3 (SeaweedFS, licence Apache 2.0)
# Données non structurées : photos des demandes, factures PDF, sauvegardes chiffrées.
#   - chiffrement au repos des données (-filer.encryptVolumeData, AES-256-GCM)
#   - un compte d'accès par usage, limité à ses buckets (moindre privilège)
# Choix : MinIO a cessé de publier ses images communautaires en 2025 ; SeaweedFS est
# une alternative open source maintenue, qui passe à l'échelle en ajoutant des volumes.
# -----------------------------------------------------------------------------

locals {
  s3_identities = {
    identities = [
      {
        name        = "admin"
        credentials = [{ accessKey = random_password.s3_access["admin"].result, secretKey = random_password.s3_secret["admin"].result }]
        actions     = ["Admin", "Read", "Write", "List", "Tagging"]
      },
      {
        name        = "app"
        credentials = [{ accessKey = random_password.s3_access["app"].result, secretKey = random_password.s3_secret["app"].result }]
        actions     = ["Read:photos", "Write:photos", "List:photos", "Read:factures", "Write:factures", "List:factures"]
      },
      {
        # Pipelines (bloc 3) : purge des photos expirées, export des jeux d'entraînement IA
        name        = "pipeline"
        credentials = [{ accessKey = random_password.s3_access["pipeline"].result, secretKey = random_password.s3_secret["pipeline"].result }]
        actions     = ["Read:photos", "Write:photos", "List:photos", "Read:datasets", "Write:datasets", "List:datasets"]
      },
      {
        # Service IA (bloc 4) : lit les jeux d'entraînement, écrit les artefacts MLflow et les rapports de dérive
        name        = "ml"
        credentials = [{ accessKey = random_password.s3_access["ml"].result, secretKey = random_password.s3_secret["ml"].result }]
        actions     = ["Read:datasets", "List:datasets", "Read:mlflow", "Write:mlflow", "List:mlflow"]
      },
      {
        name        = "backup"
        credentials = [{ accessKey = random_password.s3_access["backup"].result, secretKey = random_password.s3_secret["backup"].result }]
        actions     = ["Read:backups", "Write:backups", "List:backups"]
      },
    ]
  }
}

resource "docker_image" "seaweedfs" {
  name         = var.images["seaweedfs"]
  keep_locally = true
}

resource "docker_volume" "object_storage" {
  name = "${local.prefix}-object-storage-data"
}

resource "docker_container" "object_storage" {
  name     = "${local.prefix}-object-storage"
  hostname = "object-storage"
  image    = docker_image.seaweedfs.image_id
  restart  = "unless-stopped"
  command = [
    "server",
    "-dir=/data",
    "-ip=object-storage",
    "-ip.bind=0.0.0.0",
    "-s3",
    "-s3.port=8333",
    "-s3.config=/etc/seaweedfs/s3.json",
    "-filer.encryptVolumeData",
    "-master.volumeSizeLimitMB=1024",
    "-volume.max=0",
    "-metricsPort=9327",
  ]

  networks_advanced {
    name    = docker_network.backend.id
    aliases = ["object-storage"]
  }
  networks_advanced {
    name = docker_network.edge.id
  }

  ports {
    internal = 8333
    external = var.ports.s3
    ip       = var.bind_address
  }

  volumes {
    volume_name    = docker_volume.object_storage.name
    container_path = "/data"
  }

  upload {
    file    = "/etc/seaweedfs/s3.json"
    content = jsonencode(local.s3_identities)
  }

  healthcheck {
    test         = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:9333/cluster/healthz || exit 1"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 6
    start_period = "20s"
  }

  dynamic "labels" {
    for_each = merge(local.common_labels, { "com.artelio.component" = "object-storage" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}
