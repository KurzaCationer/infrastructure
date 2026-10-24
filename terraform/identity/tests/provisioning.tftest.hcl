mock_provider "pocketid" {
  mock_resource "pocketid_group" {
    defaults = { id = "00000000-0000-0000-0000-000000000010" }
  }
  mock_resource "pocketid_client" {
    defaults = {
      id            = "argocd"
      client_secret = "mock-generated-client-secret"
    }
  }
}
mock_provider "bitwarden-secrets" {
  mock_resource "bitwarden-secrets_secret" {
    defaults = { id = "00000000-0000-0000-0000-000000000011" }
  }
}
mock_provider "kubernetes" {}

override_data {
  target = data.terraform_remote_state.cluster
  values = {
    outputs = {
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

override_data {
  target = data.terraform_remote_state.bootstrap
  values = {
    outputs = {
      argocd_url = "https://argocd.test.ts.net"
      pocket_id = {
        url               = "https://auth.kurza.nl"
        api_key_secret_id = "00000000-0000-0000-0000-000000000005"
        project_id        = "00000000-0000-0000-0000-000000000006"
      }
    }
  }
}

variables {
  state_bucket = "test-state"
  aws_region   = "eu-central-1"
}

run "provision_sso" {
  command = apply

  assert {
    condition = (
      pocketid_client.argocd.client_id == "argocd" &&
      pocketid_client.argocd.callback_urls == tolist(["https://argocd.test.ts.net/auth/callback"]) &&
      pocketid_client.argocd.pkce_enabled &&
      !pocketid_client.argocd.is_public &&
      pocketid_client.argocd.is_group_restricted &&
      pocketid_client.argocd.allowed_user_groups == toset([pocketid_group.argocd_admins.id])
    )
    error_message = "Argo CD must use a confidential PKCE client restricted to its administrator group and private callback."
  }

  assert {
    condition = (
      bitwarden-secrets_secret.argocd_client.value == pocketid_client.argocd.client_secret &&
      kubernetes_secret_v1.argocd_oidc.data["client-secret"] == bitwarden-secrets_secret.argocd_client.value &&
      kubernetes_secret_v1.argocd_oidc.metadata[0].labels["app.kubernetes.io/part-of"] == "argocd"
    )
    error_message = "The generated client secret must reach Bitwarden and the labelled Argo CD Secret without manual inputs."
  }

  assert {
    condition = (
      toset(keys(kubernetes_config_map_v1_data.argocd_oidc.data)) == toset(["oidc.config"]) &&
      yamldecode(kubernetes_config_map_v1_data.argocd_oidc.data["oidc.config"]).clientSecret == "$argocd-pocket-id:client-secret" &&
      yamldecode(kubernetes_config_map_v1_data.argocd_oidc.data["oidc.config"]).issuer == "https://auth.kurza.nl"
    )
    error_message = "Identity must own only oidc.config and reference the Secret instead of embedding its value."
  }
}

run "repeat_plan" {
  command = plan

  assert {
    condition = (
      bitwarden-secrets_secret.argocd_client.value == "mock-generated-client-secret" &&
      kubernetes_secret_v1.argocd_oidc.data["client-secret"] == "mock-generated-client-secret"
    )
    error_message = "A subsequent plan must reuse the client secret retained in state."
  }
}
