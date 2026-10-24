output "argocd_url" {
  description = "Private HTTPS URL, reachable from authorized tailnet devices after service approval."
  value       = local.argocd_url
}

output "pocket_id" {
  description = "Non-secret references used by the identity layer."
  value = {
    url               = "https://auth.kurza.nl"
    api_key_secret_id = bitwarden-secrets_secret.pocket_id_api.id
    project_id        = var.bitwarden_identity_project_id
  }
}
