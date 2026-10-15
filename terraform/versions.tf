terraform {
  required_version = ">= 1.6"

  required_providers {
    # Pilote le démon Docker local : l'infrastructure "on-premise" simulée d'Artelio
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.6"
    }
    # Génère les secrets (mots de passe) : aucun secret n'est écrit dans le code
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # Génère l'autorité de certification et les certificats TLS internes
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "docker" {
  host = var.docker_host
}
