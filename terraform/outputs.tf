output "urls" {
  description = "Interfaces accessibles depuis la machine locale"
  value = {
    grafana      = "http://localhost:${var.ports.grafana}"
    prometheus   = "http://localhost:${var.ports.prometheus}"
    alertmanager = "http://localhost:${var.ports.alertmanager}"
    s3_endpoint  = "http://localhost:${var.ports.s3}"
    postgres     = "localhost:${var.ports.postgres_primary} (primaire) / localhost:${var.ports.postgres_replica} (réplica), TLS obligatoire"
    kafka        = "localhost:${var.ports.kafka}"
  }
}

output "containers" {
  description = "Conteneurs déployés"
  value = concat(
    [
      docker_container.pg_primary.name,
      docker_container.pg_replica.name,
      docker_container.object_storage.name,
      docker_container.kafka.name,
      docker_container.backup.name,
      docker_container.prometheus.name,
      docker_container.alertmanager.name,
      docker_container.pushgateway.name,
      docker_container.grafana.name,
      docker_container.kafka_exporter.name,
    ],
    [for c in docker_container.pg_exporter : c.name],
  )
}

# Secrets : affichés uniquement sur demande explicite (terraform output -json secrets)
output "secrets" {
  description = "Mots de passe générés (sensibles)"
  sensitive   = true
  value = {
    grafana_admin        = random_password.grafana_admin.result
    postgres_admin       = random_password.db["admin"].result
    postgres_app_api     = random_password.db["app_api"].result
    postgres_analyst     = random_password.db["analyst"].result
    postgres_dpo         = random_password.db["dpo_officer"].result
    postgres_pipeline    = random_password.db["pipeline_etl"].result
    s3_app_access_key    = random_password.s3_access["app"].result
    s3_app_secret_key    = random_password.s3_secret["app"].result
    pseudonymisation_key = random_password.pseudonymisation_key.result
    s3_pipeline_access   = random_password.s3_access["pipeline"].result
    s3_pipeline_secret   = random_password.s3_secret["pipeline"].result
  }
}

output "ca_certificate" {
  description = "Certificat de l'autorité interne (pour vérifier le TLS de PostgreSQL : sslmode=verify-full)"
  value       = tls_self_signed_cert.ca.cert_pem
}
