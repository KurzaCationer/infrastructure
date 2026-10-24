resource "kubernetes_namespace_v1" "external_dns" {
  metadata {
    name = "external-dns"
  }
}

resource "kubernetes_namespace_v1" "pocket_id" {
  metadata {
    name = "pocket-id"
    labels = {
      "infrastructure.kurza.nl/public-ingress" = "true"
    }
  }
}

resource "kubernetes_secret_v1" "identity_bitwarden_auth" {
  metadata {
    name      = "bitwarden-auth"
    namespace = kubernetes_namespace_v1.pocket_id.metadata[0].name
  }
  data_wo = {
    token = var.bitwarden_operator_access_token
  }
  data_wo_revision = var.bitwarden_operator_access_token_revision
  type             = "Opaque"
}

provider "bitwarden-secrets" {}

resource "bitwarden-secrets_secret" "pocket_id_encryption" {
  key        = "pocket-id-encryption-key"
  project_id = var.bitwarden_identity_project_id
  length     = 64
  special    = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "bitwarden-secrets_secret" "pocket_id_api" {
  key        = "pocket-id-provisioning-api-key"
  project_id = var.bitwarden_identity_project_id
  length     = 64
  special    = false
}

# cert-manager's namespace already belongs to Kube-Hetzner. Only initialize
# operator authentication here; Argo CD owns the Cloudflare mappings and apps.
resource "kubernetes_secret_v1" "public_bitwarden_auth" {
  for_each = toset(["cert-manager", "external-dns"])

  metadata {
    name      = "bitwarden-auth"
    namespace = each.key
  }
  data_wo = {
    token = var.bitwarden_operator_access_token
  }
  data_wo_revision = var.bitwarden_operator_access_token_revision
  type             = "Opaque"

  depends_on = [kubernetes_namespace_v1.external_dns]
}
