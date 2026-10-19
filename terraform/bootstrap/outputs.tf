output "argocd_url" {
  description = "Private HTTPS URL, reachable from authorized tailnet devices after service approval."
  value       = local.argocd_url
}

output "kubeconfig" {
  description = "Admin kubeconfig used transiently by CI to initialize namespace-local BWS auth."
  value       = data.terraform_remote_state.cluster.outputs.kubeconfig
  sensitive   = true
}
