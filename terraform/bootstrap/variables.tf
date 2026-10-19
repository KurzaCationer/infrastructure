variable "state_bucket" {
  description = "Existing S3 bucket containing the cluster and bootstrap states."
  type        = string
}

variable "aws_region" {
  description = "AWS region of the existing state bucket."
  type        = string
}

variable "tailscale_magicdns_domain" {
  description = "Tailnet MagicDNS domain, without a trailing dot."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+\\.ts\\.net$", var.tailscale_magicdns_domain))
    error_message = "Provide the tailnet domain, for example example-tailnet.ts.net."
  }
}

variable "bitwarden_organization_id" {
  description = "Bitwarden organization UUID used by the in-cluster secrets operator."
  type        = string
}

variable "bitwarden_operator_access_token" {
  description = "Bitwarden machine token for the in-cluster operator; never saved in plans or state."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = trimspace(var.bitwarden_operator_access_token) != ""
    error_message = "Provide the Bitwarden operator machine token."
  }
}

variable "bitwarden_operator_access_token_revision" {
  description = "Increment when rotating the write-only Bitwarden operator token."
  type        = number
  default     = 1

  validation {
    condition     = var.bitwarden_operator_access_token_revision >= 1 && floor(var.bitwarden_operator_access_token_revision) == var.bitwarden_operator_access_token_revision
    error_message = "The token revision must be a positive integer."
  }
}

variable "bitwarden_api_url" {
  description = "Bitwarden API endpoint (US, EU, or self-hosted)."
  type        = string
  default     = "https://api.bitwarden.com"
}

variable "bitwarden_identity_url" {
  description = "Bitwarden identity endpoint matching the API endpoint."
  type        = string
  default     = "https://identity.bitwarden.com"
}

variable "tailscale_operator_secret_ids" {
  description = "Bitwarden secret UUIDs for the operator OAuth client ID and secret; never their values."
  type = object({
    client_id     = string
    client_secret = string
  })

  validation {
    condition = alltrue([
      for id in values(var.tailscale_operator_secret_ids) :
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))
    ])
    error_message = "Provide Bitwarden UUIDs for both OAuth credential secrets."
  }
}
