resource "kubernetes_namespace_v1" "external_dns" {
  metadata {
    name = "external-dns"
  }
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
