output "argocd_url" {
  description = "Private HTTPS URL, reachable from authorized tailnet devices after service approval."
  value       = local.argocd_url
}
