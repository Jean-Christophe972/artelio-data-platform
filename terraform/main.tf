# -----------------------------------------------------------------------------
# Réseaux : segmentation (recommandation ANSSI — cloisonner les flux)
#   - backend : réseau interne, sans accès Internet, où vivent les données
#   - edge    : seuls les services qu'un humain doit consulter y sont branchés,
#               et leurs ports ne sont publiés que sur 127.0.0.1
# -----------------------------------------------------------------------------

locals {
  prefix   = var.environment
  root_dir = abspath("${path.module}/..")
  docker   = "${local.root_dir}/docker"

  common_labels = {
    "com.artelio.project"     = "data-platform"
    "com.artelio.environment" = var.environment
    "com.artelio.managed-by"  = "terraform"
  }
}

resource "docker_network" "backend" {
  name     = "${local.prefix}-backend"
  driver   = "bridge"
  internal = true

  labels {
    label = "com.artelio.role"
    value = "donnees"
  }
}

resource "docker_network" "edge" {
  name   = "${local.prefix}-edge"
  driver = "bridge"

  labels {
    label = "com.artelio.role"
    value = "exposition-locale"
  }
}
