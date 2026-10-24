terraform {
  required_version = ">= 1.16.6, < 2.0"

  required_providers {
    bitwarden-secrets = {
      source  = "bitwarden/bitwarden-secrets"
      version = "~> 1.0"
    }
    pocketid = {
      source  = "irashack/pocketid"
      version = "3.1.4"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }

  backend "s3" {
    key          = "identity/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
