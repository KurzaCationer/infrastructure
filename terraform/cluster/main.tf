provider "bitwarden-secrets" {}

data "bitwarden-secrets_secret" "hcloud_token" {
  id = var.bitwarden_secret_ids.hcloud_token
}

data "bitwarden-secrets_secret" "ssh_public_key" {
  id = var.bitwarden_secret_ids.ssh_public_key
}

data "bitwarden-secrets_secret" "ssh_private_key" {
  id = var.bitwarden_secret_ids.ssh_private_key
}

provider "hcloud" {
  token = data.bitwarden-secrets_secret.hcloud_token.value
}

module "cluster" {
  source  = "kube-hetzner/kube-hetzner/hcloud"
  version = "3.2.1"

  providers = {
    hcloud = hcloud
  }

  cluster_name    = var.cluster_name
  hcloud_token    = data.bitwarden-secrets_secret.hcloud_token.value
  ssh_public_key  = trimspace(data.bitwarden-secrets_secret.ssh_public_key.value)
  ssh_private_key = data.bitwarden-secrets_secret.ssh_private_key.value

  enabled_architectures = startswith(var.server_type, "cax") ? ["arm"] : ["x86"]
  network_region        = "eu-central"

  # Enroll before Terraform's first SSH connection, with no public SSH/API rule.
  node_transport_mode      = "tailscale"
  firewall_ssh_source      = null
  firewall_kube_api_source = null
  tailscale_auth_key       = var.tailscale_auth_key
  tailscale_node_transport = {
    bootstrap_mode  = "cloud_init"
    magicdns_domain = var.tailscale_magicdns_domain
    auth = {
      mode                         = "auth_key"
      advertise_tags_control_plane = ["tag:kurza-cluster"]
    }
    routing = {
      advertise_node_private_routes = false
    }
    # Required by kube-hetzner v3.2.1 when combining Cilium and Tailscale.
    enable_experimental_cilium = true
  }

  control_plane_nodepools = [{
    name        = "control-plane"
    server_type = var.server_type
    location    = var.location
    count       = 1
    labels      = []
    taints      = []
  }]

  agent_nodepools                   = []
  allow_scheduling_on_control_plane = true

  # Cilium provides both the CNI and Gateway API controller; no Traefik.
  cni_plugin                 = "cilium"
  enable_kube_proxy          = false
  cilium_gateway_api_enabled = true
  ingress_controller         = "none"
  cilium_merge_values = yamlencode({
    operator = {
      replicas = 1
    }
    gatewayAPI = {
      hostNetwork = {
        enabled = true
      }
    }
    envoy = {
      enabled = true
      securityContext = {
        capabilities = {
          keepCapNetBindService = true
          envoy                 = ["NET_ADMIN", "SYS_ADMIN", "NET_BIND_SERVICE"]
        }
      }
    }
  })

  # Kube-Hetzner 3.2.1 merges rules by direction/protocol/port. These replace
  # its single-node defaults that otherwise allow 80/443 from the whole world.
  extra_firewall_rules = [for port in ["80", "443"] : {
    description = "Cloudflare proxy only TCP ${port}"
    direction   = "in"
    protocol    = "tcp"
    port        = port
    source_ips  = local.cloudflare_proxy_cidrs
  }]

  # Tailscale transport disables CCM networking defaults. Keep private node
  # address discovery enabled without enabling Hetzner pod-route management.
  hetzner_ccm_merge_values = yamlencode({
    env = {
      HCLOUD_NETWORK = {
        valueFrom = {
          secretKeyRef = {
            name = "hcloud"
            key  = "network"
          }
        }
      }
    }
  })

  # Keep this single-node cluster's upgrades manual.
  automatically_upgrade_os         = false
  automatically_upgrade_kubernetes = false
  create_kubeconfig                = false
  create_kustomization             = false
}
