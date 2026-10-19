terraform {
  required_version = ">= 1.16.6, < 2.0"

  required_providers {
    bitwarden-secrets = {
      source  = "bitwarden/bitwarden-secrets"
      version = "~> 1.0"
    }
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.62"
    }
  }

  backend "s3" {
    key          = "cluster/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
