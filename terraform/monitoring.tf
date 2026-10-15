# -----------------------------------------------------------------------------
# Observabilité : Prometheus (métriques + règles d'alerte), Alertmanager (notification),
# Pushgateway (métriques des jobs ponctuels), Grafana (tableaux de bord).
# -----------------------------------------------------------------------------

locals {
  monitoring_dir = "${local.docker}/monitoring"
  dashboards     = fileset("${local.monitoring_dir}/grafana/dashboards", "*.json")
}

resource "docker_image" "prometheus" {
  name         = var.images["prometheus"]
  keep_locally = true
}

resource "docker_image" "alertmanager" {
  name         = var.images["alertmanager"]
  keep_locally = true
}

resource "docker_image" "pushgateway" {
  name         = var.images["pushgateway"]
  keep_locally = true
}

resource "docker_image" "grafana" {
  name         = var.images["grafana"]
  keep_locally = true
}

resource "docker_volume" "prometheus" {
  name = "${local.prefix}-prometheus-data"
}

resource "docker_volume" "grafana" {
  name = "${local.prefix}-grafana-data"
}

resource "docker_container" "prometheus" {
  name    = "${local.prefix}-prometheus"
  image   = docker_image.prometheus.image_id
  restart = "unless-stopped"
  command = [
    "--config.file=/etc/prometheus/prometheus.yml",
    "--storage.tsdb.path=/prometheus",
    "--storage.tsdb.retention.time=15d",
    "--web.enable-lifecycle",
  ]

  networks_advanced {
    name    = docker_network.backend.id
    aliases = ["prometheus"]
  }
  networks_advanced {
    name = docker_network.edge.id
  }

  ports {
    internal = 9090
    external = var.ports.prometheus
    ip       = var.bind_address
  }

  volumes {
    volume_name    = docker_volume.prometheus.name
    container_path = "/prometheus"
  }

  upload {
    file        = "/etc/prometheus/prometheus.yml"
    source      = "${local.monitoring_dir}/prometheus.yml"
    source_hash = filesha256("${local.monitoring_dir}/prometheus.yml")
  }
  upload {
    file        = "/etc/prometheus/alert_rules.yml"
    source      = "${local.monitoring_dir}/alert_rules.yml"
    source_hash = filesha256("${local.monitoring_dir}/alert_rules.yml")
  }

  dynamic "labels" {
    for_each = merge(local.common_labels, { "com.artelio.component" = "monitoring" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_container" "alertmanager" {
  name    = "${local.prefix}-alertmanager"
  image   = docker_image.alertmanager.image_id
  restart = "unless-stopped"
  command = ["--config.file=/etc/alertmanager/alertmanager.yml", "--storage.path=/alertmanager"]

  networks_advanced {
    name    = docker_network.backend.id
    aliases = ["alertmanager"]
  }
  networks_advanced {
    name = docker_network.edge.id
  }

  ports {
    internal = 9093
    external = var.ports.alertmanager
    ip       = var.bind_address
  }

  upload {
    file        = "/etc/alertmanager/alertmanager.yml"
    source      = "${local.monitoring_dir}/alertmanager.yml"
    source_hash = filesha256("${local.monitoring_dir}/alertmanager.yml")
  }

  dynamic "labels" {
    for_each = merge(local.common_labels, { "com.artelio.component" = "monitoring" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_container" "pushgateway" {
  name    = "${local.prefix}-pushgateway"
  image   = docker_image.pushgateway.image_id
  restart = "unless-stopped"

  networks_advanced {
    name    = docker_network.backend.id
    aliases = ["pushgateway"]
  }

  dynamic "labels" {
    for_each = merge(local.common_labels, { "com.artelio.component" = "monitoring" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_container" "grafana" {
  name    = "${local.prefix}-grafana"
  image   = docker_image.grafana.image_id
  restart = "unless-stopped"

  env = [
    "GF_SECURITY_ADMIN_USER=admin",
    "GF_SECURITY_ADMIN_PASSWORD=${random_password.grafana_admin.result}",
    "GF_USERS_ALLOW_SIGN_UP=false",
    "GF_AUTH_ANONYMOUS_ENABLED=false",
    "GF_ANALYTICS_REPORTING_ENABLED=false",
    "GF_DEFAULT_LOCALE=fr-FR",
    "GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/plateforme.json",
  ]

  networks_advanced {
    name    = docker_network.backend.id
    aliases = ["grafana"]
  }
  networks_advanced {
    name = docker_network.edge.id
  }

  ports {
    internal = 3000
    external = var.ports.grafana
    ip       = var.bind_address
  }

  volumes {
    volume_name    = docker_volume.grafana.name
    container_path = "/var/lib/grafana"
  }

  upload {
    file = "/etc/grafana/provisioning/datasources/datasources.yml"
    content = templatefile("${local.monitoring_dir}/grafana/provisioning/datasources/datasources.yml.tftpl", {
      analyst_password = random_password.db["analyst"].result
    })
  }
  upload {
    file        = "/etc/grafana/provisioning/dashboards/dashboards.yml"
    source      = "${local.monitoring_dir}/grafana/provisioning/dashboards/dashboards.yml"
    source_hash = filesha256("${local.monitoring_dir}/grafana/provisioning/dashboards/dashboards.yml")
  }

  dynamic "upload" {
    for_each = local.dashboards
    content {
      file        = "/var/lib/grafana/dashboards/${upload.value}"
      source      = "${local.monitoring_dir}/grafana/dashboards/${upload.value}"
      source_hash = filesha256("${local.monitoring_dir}/grafana/dashboards/${upload.value}")
    }
  }

  dynamic "labels" {
    for_each = merge(local.common_labels, { "com.artelio.component" = "monitoring" })
    content {
      label = labels.key
      value = labels.value
    }
  }

  depends_on = [docker_container.prometheus]
}
