# -----------------------------------------------------------------------------
# Apache Kafka (mode KRaft, sans ZooKeeper) : bus d'événements temps réel.
# Absorbe la vélocité (pics de ~200 événements/s) entre l'application et les
# pipelines du bloc 3 ; les topics sont créés par le job d'initialisation (tools.tf).
# Environnement local : 1 broker. Production : 3 brokers, facteur de réplication 3,
# min.insync.replicas = 2, chiffrement SASL_SSL (voir docs/ARCHITECTURE.md).
# -----------------------------------------------------------------------------

resource "docker_image" "kafka" {
  name         = var.images["kafka"]
  keep_locally = true
}

resource "docker_volume" "kafka" {
  name = "${local.prefix}-kafka-data"
}

resource "docker_container" "kafka" {
  name     = "${local.prefix}-kafka"
  hostname = "kafka"
  image    = docker_image.kafka.image_id
  restart  = "unless-stopped"

  env = [
    "CLUSTER_ID=QXJ0ZWxpb0thZmthQ2x1cw",
    "KAFKA_NODE_ID=1",
    "KAFKA_PROCESS_ROLES=broker,controller",
    "KAFKA_LISTENERS=INTERNAL://:9092,CONTROLLER://:9093,EXTERNAL://:9094",
    "KAFKA_ADVERTISED_LISTENERS=INTERNAL://kafka:9092,EXTERNAL://localhost:${var.ports.kafka}",
    "KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=INTERNAL:PLAINTEXT,CONTROLLER:PLAINTEXT,EXTERNAL:PLAINTEXT",
    "KAFKA_CONTROLLER_QUORUM_VOTERS=1@kafka:9093",
    "KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER",
    "KAFKA_INTER_BROKER_LISTENER_NAME=INTERNAL",
    "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1",
    "KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1",
    "KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1",
    "KAFKA_AUTO_CREATE_TOPICS_ENABLE=false",
    "KAFKA_LOG_RETENTION_HOURS=168",
    "KAFKA_LOG_DIRS=/var/lib/kafka/data",
    "KAFKA_HEAP_OPTS=-Xms512m -Xmx512m",
  ]

  networks_advanced {
    name    = docker_network.backend.id
    aliases = ["kafka"]
  }
  networks_advanced {
    name = docker_network.edge.id
  }

  ports {
    internal = 9094
    external = var.ports.kafka
    ip       = var.bind_address
  }

  volumes {
    volume_name    = docker_volume.kafka.name
    container_path = "/var/lib/kafka/data"
  }

  healthcheck {
    test         = ["CMD-SHELL", "/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 > /dev/null 2>&1"]
    interval     = "30s"
    timeout      = "20s"
    retries      = 5
    start_period = "40s"
  }

  dynamic "labels" {
    for_each = merge(local.common_labels, { "com.artelio.component" = "kafka" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_image" "kafka_exporter" {
  name         = var.images["kafka_exporter"]
  keep_locally = true
}

resource "docker_container" "kafka_exporter" {
  name    = "${local.prefix}-kafka-exporter"
  image   = docker_image.kafka_exporter.image_id
  restart = "unless-stopped"
  command = ["--kafka.server=kafka:9092"]

  networks_advanced {
    name    = docker_network.backend.id
    aliases = ["kafka-exporter"]
  }

  dynamic "labels" {
    for_each = merge(local.common_labels, { "com.artelio.component" = "monitoring" })
    content {
      label = labels.key
      value = labels.value
    }
  }

  depends_on = [docker_container.kafka]
}
