data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    region = var.aws_region
    key    = "cluster/terraform.tfstate"
  }
}

data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    region = var.aws_region
    key    = "bootstrap/terraform.tfstate"
  }
}

locals {
  kubeconfig = yamldecode(data.terraform_remote_state.cluster.outputs.kubeconfig)
  cluster    = local.kubeconfig.clusters[0].cluster
  user       = local.kubeconfig.users[0].user
  pocket_id  = data.terraform_remote_state.bootstrap.outputs.pocket_id
  argocd_url = data.terraform_remote_state.bootstrap.outputs.argocd_url
}

provider "bitwarden-secrets" {}

data "bitwarden-secrets_secret" "pocket_id_api" {
  id = local.pocket_id.api_key_secret_id
}

provider "pocketid" {
  base_url  = local.pocket_id.url
  api_token = data.bitwarden-secrets_secret.pocket_id_api.value
}

provider "kubernetes" {
  host                   = local.cluster.server
  cluster_ca_certificate = base64decode(local.cluster["certificate-authority-data"])
  client_certificate     = base64decode(local.user["client-certificate-data"])
  client_key             = base64decode(local.user["client-key-data"])
}

resource "pocketid_group" "argocd_admins" {
  name          = "argocd-admins"
  friendly_name = "Argo CD administrators"
}

resource "pocketid_client" "argocd" {
  name                = "Argo CD"
  client_id           = "argocd"
  callback_urls       = ["${local.argocd_url}/auth/callback"]
  launch_url          = local.argocd_url
  is_public           = false
  pkce_enabled        = true
  is_group_restricted = true
  allowed_user_groups = [pocketid_group.argocd_admins.id]
  generate_secret     = true
}

resource "bitwarden-secrets_secret" "argocd_client" {
  key        = "argocd-pocket-id-client-secret"
  project_id = local.pocket_id.project_id
  value      = pocketid_client.argocd.client_secret
}

# The value is already sensitive state in Pocket ID and Bitwarden resources.
# Terraform owns this Secret; the operator does not reconcile it.
resource "kubernetes_secret_v1" "argocd_oidc" {
  metadata {
    name      = "argocd-pocket-id"
    namespace = "argocd"
    labels    = { "app.kubernetes.io/part-of" = "argocd" }
  }
  data = {
    client-secret = bitwarden-secrets_secret.argocd_client.value
  }
}

# Own only this additional data key. Helm continues to manage the ConfigMap's
# other fields and must not declare oidc.config in its values.
resource "kubernetes_config_map_v1_data" "argocd_oidc" {
  metadata {
    name      = "argocd-cm"
    namespace = "argocd"
  }
  field_manager = "terraform-identity"
  data = {
    "oidc.config" = yamlencode({
      name                     = "Pocket ID"
      issuer                   = local.pocket_id.url
      clientID                 = pocketid_client.argocd.id
      clientSecret             = "$argocd-pocket-id:client-secret"
      requestedScopes          = ["openid", "profile", "email", "groups"]
      requestedIDTokenClaims   = { groups = { essential = true } }
      enablePKCEAuthentication = true
    })
  }
  depends_on = [kubernetes_secret_v1.argocd_oidc]
}
