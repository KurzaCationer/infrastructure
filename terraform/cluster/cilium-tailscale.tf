locals {
  # Tailscale enables src_valid_mark globally. Allow Cilium's transparent-proxy
  # return traffic through Linux source validation (tailscale/tailscale#19796).
  cilium_tailscale_sysctl = <<-EOT
    set -eu
    install -d -m 0755 /etc/sysctl.d
    printf '%s\n' 'net.ipv4.conf.all.accept_local = 1' > /etc/sysctl.d/90-cilium-tailscale.conf
    chmod 0644 /etc/sysctl.d/90-cilium-tailscale.conf
    sysctl -p /etc/sysctl.d/90-cilium-tailscale.conf
  EOT
}

resource "terraform_data" "cilium_tailscale_sysctl" {
  for_each = merge(
    { for key, host in module.cluster.tailscale_control_plane_magicdns_hosts : "control-plane:${key}" => {
      host = host
      id   = module.cluster.control_planes[key].id
    } },
    { for key, host in module.cluster.tailscale_agent_magicdns_hosts : "agent:${key}" => {
      host = host
      id   = module.cluster.agents[key].id
    } }
  )

  triggers_replace = [each.value.id, sha256(local.cilium_tailscale_sysctl)]

  connection {
    type        = "ssh"
    user        = "root"
    host        = each.value.host
    private_key = data.bitwarden-secrets_secret.ssh_private_key.value
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [local.cilium_tailscale_sysctl]
  }
}
