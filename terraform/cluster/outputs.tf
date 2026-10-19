output "kubeconfig" {
  description = "Admin kubeconfig for the bootstrap layer and local access."
  value       = module.cluster.kubeconfig
  sensitive   = true
}

output "control_plane_hostname" {
  description = "Private MagicDNS hostname for SSH to the control-plane node."
  value       = values(module.cluster.tailscale_control_plane_magicdns_hosts)[0]
}
