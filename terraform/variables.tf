variable "docker_host" {
  description = "Socket du démon Docker"
  type        = string
  default     = "unix:///var/run/docker.sock"
}

variable "environment" {
  description = "Nom de l'environnement (préfixe des ressources)"
  type        = string
  default     = "artelio"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.environment))
    error_message = "environment : minuscules, chiffres et tirets, 3 à 21 caractères."
  }
}

variable "bind_address" {
  description = "Adresse d'écoute des ports publiés. 127.0.0.1 = rien n'est exposé hors de la machine."
  type        = string
  default     = "127.0.0.1"
}

variable "ports" {
  description = "Ports publiés sur l'hôte (choisis pour ne pas entrer en conflit avec d'autres projets)"
  type = object({
    postgres_primary = number
    postgres_replica = number
    s3               = number
    kafka            = number
    prometheus       = number
    alertmanager     = number
    grafana          = number
  })
  default = {
    postgres_primary = 15432
    postgres_replica = 15433
    s3               = 18333
    kafka            = 19094
    prometheus       = 19090
    alertmanager     = 19093
    grafana          = 13000
  }
}

variable "images" {
  description = "Images Docker, toutes épinglées sur une version précise (reproductibilité)"
  type        = map(string)
  default = {
    postgres          = "postgres:16.10"
    seaweedfs         = "chrislusf/seaweedfs:3.97"
    kafka             = "apache/kafka:3.9.1"
    prometheus        = "prom/prometheus:v3.5.0"
    alertmanager      = "prom/alertmanager:v0.28.1"
    pushgateway       = "prom/pushgateway:v1.11.1"
    grafana           = "grafana/grafana:12.1.1"
    postgres_exporter = "prometheuscommunity/postgres-exporter:v0.17.1"
    kafka_exporter    = "danielqsj/kafka-exporter:v1.9.0"
  }
}

variable "backup_interval_seconds" {
  description = "Intervalle entre deux sauvegardes PostgreSQL (RPO cible : 1 h)"
  type        = number
  default     = 3600
}

variable "backup_retention_days" {
  description = "Durée de conservation des sauvegardes dans le stockage objet"
  type        = number
  default     = 30
}

variable "kafka_topics" {
  description = "Topics Kafka (flux temps réel) et leur nombre de partitions"
  type        = map(number)
  default = {
    "demandes.creees"        = 6
    "messages.envoyes"       = 6
    "artisans.disponibilite" = 3
    "interventions.statut"   = 3
    "dlq.erreurs"            = 1
  }
}
