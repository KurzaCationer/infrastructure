mock_provider "kubernetes" {}
mock_provider "helm" {}

override_data {
  target = data.terraform_remote_state.cluster
  values = {
    outputs = {
      public_ingress_ipv4 = "192.0.2.10"
      kubeconfig = yamlencode({
        clusters = [{ cluster = {
          server                     = "https://192.0.2.10:6443"
          certificate-authority-data = base64encode("test-ca")
        } }]
        users = [{ user = {
          client-certificate-data = base64encode("test-cert")
          client-key-data         = base64encode("test-key")
        } }]
      })
    }
  }
}

variables {
  state_bucket                    = "test-state"
  aws_region                      = "eu-central-1"
  tailscale_magicdns_domain       = "test.ts.net"
  bitwarden_organization_id       = "00000000-0000-0000-0000-000000000001"
  bitwarden_operator_access_token = "local-test-token"
  tailscale_operator_secret_ids = {
    client_id     = "00000000-0000-0000-0000-000000000002"
    client_secret = "00000000-0000-0000-0000-000000000003"
  }
}

run "fresh_credentials" {
  command = plan

  assert {
    condition = (
      kubernetes_secret_v1.bitwarden_auth.metadata[0].namespace == "tailscale" &&
      toset([for secret in kubernetes_secret_v1.public_bitwarden_auth : secret.metadata[0].namespace]) == toset(["cert-manager", "external-dns"])
    )
    error_message = "Fresh bootstrap must initialize BWS auth in all three namespaces."
  }
}

run "rotate_credentials" {
  command = plan
  variables {
    bitwarden_operator_access_token          = "local-rotated-token"
    bitwarden_operator_access_token_revision = 2
  }

  assert {
    condition = (
      kubernetes_secret_v1.bitwarden_auth.data_wo_revision == 2 &&
      alltrue([for secret in kubernetes_secret_v1.public_bitwarden_auth : secret.data_wo_revision == 2])
    )
    error_message = "One operator-token revision must rotate all three auth Secrets."
  }
}
