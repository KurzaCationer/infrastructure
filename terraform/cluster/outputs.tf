output "kubeconfig" {
  description = "Admin kubeconfig for the bootstrap layer and local access."
  value       = module.cluster.kubeconfig
  sensitive   = true
}

output "public_ingress_ipv4" {
  description = "Single-node public origin address; HTTP(S) accepts Cloudflare proxy ranges only."
  value       = one(module.cluster.control_planes_public_ipv4)
}

output "control_plane_hostname" {
  description = "Private MagicDNS hostname for SSH to the control-plane node."
  value       = values(module.cluster.tailscale_control_plane_magicdns_hosts)[0]
}
