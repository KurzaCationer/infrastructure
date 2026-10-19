data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    region = var.aws_region
    key    = "cluster/terraform.tfstate"
  }
}

locals {
  kubeconfig = yamldecode(data.terraform_remote_state.cluster.outputs.kubeconfig)
  cluster    = local.kubeconfig.clusters[0].cluster
  user       = local.kubeconfig.users[0].user
  argocd_url = "https://argocd.${var.tailscale_magicdns_domain}"
}

provider "kubernetes" {
  host                   = local.cluster.server
  cluster_ca_certificate = base64decode(local.cluster["certificate-authority-data"])
  client_certificate     = base64decode(local.user["client-certificate-data"])
  client_key             = base64decode(local.user["client-key-data"])
}

resource "kubernetes_namespace_v1" "tailscale" {
  metadata {
    name = "tailscale"
  }
}

resource "kubernetes_secret_v1" "bitwarden_auth" {
  metadata {
    name      = "bitwarden-auth"
    namespace = kubernetes_namespace_v1.tailscale.metadata[0].name
  }

  # The input is ephemeral and this argument is write-only: neither the input
  # nor the Kubernetes Secret payload is retained in saved plans or state.
  data_wo = {
    token = var.bitwarden_operator_access_token
  }
  data_wo_revision = var.bitwarden_operator_access_token_revision
  type             = "Opaque"
}

provider "helm" {
  kubernetes = {
    host                   = local.cluster.server
    cluster_ca_certificate = base64decode(local.cluster["certificate-authority-data"])
    client_certificate     = base64decode(local.user["client-certificate-data"])
    client_key             = base64decode(local.user["client-key-data"])
  }
}

resource "helm_release" "bitwarden_operator" {
  name             = "sm-operator"
  namespace        = "sm-operator-system"
  create_namespace = true
  repository       = "https://charts.bitwarden.com"
  chart            = "sm-operator"
  version          = "2.0.3"
  atomic           = true
  timeout          = 600

  values = [yamlencode({
    settings = {
      cloudRegion           = ""
      bwApiUrlOverride      = var.bitwarden_api_url
      bwIdentityUrlOverride = var.bitwarden_identity_url
    }
  })]
}

# Only UUIDs and Secret references enter this release. The Bitwarden operator
# fetches the credential values directly and owns the resulting operator-oauth.
resource "helm_release" "tailscale_credentials" {
  name      = "tailscale-credentials"
  namespace = kubernetes_namespace_v1.tailscale.metadata[0].name
  chart     = "${path.module}/charts/tailscale-credentials"
  atomic    = true
  timeout   = 600

  values = [yamlencode({
    organizationId = var.bitwarden_organization_id
    clientId       = var.tailscale_operator_secret_ids.client_id
    clientSecret   = var.tailscale_operator_secret_ids.client_secret
  })]

  depends_on = [helm_release.bitwarden_operator, kubernetes_secret_v1.bitwarden_auth]
}

resource "helm_release" "tailscale_operator" {
  name       = "tailscale-operator"
  namespace  = kubernetes_namespace_v1.tailscale.metadata[0].name
  repository = "https://pkgs.tailscale.com/helmcharts"
  chart      = "tailscale-operator"
  version    = "1.104.1"
  atomic     = true
  timeout    = 600

  values = [yamlencode({
    # The chart must not create the OAuth Secret or receive credential values.
    oauthSecretVolume = {
      secret = {
        secretName = "operator-oauth"
      }
    }
    operatorConfig = {
      hostname    = "kurza-k8s-operator"
      defaultTags = ["tag:kurza-k8s-operator"]
    }
    proxyConfig = {
      defaultTags = "tag:kurza-k8s-proxy"
    }
    apiServerProxyConfig = {
      mode = "false"
    }
  })]

  # Readiness waits for Bitwarden to populate the mounted Secret on first boot.
  depends_on = [helm_release.tailscale_credentials]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.10.5"
  atomic           = true
  timeout          = 600

  values = [
    file("${path.module}/values/argocd.yaml"),
    yamlencode({
      configs = {
        cm = {
          url = local.argocd_url
        }
      }
    }),
  ]

  # extraObjects includes a ProxyGroup. Helm creates it only after the operator
  # has installed its CRDs; Terraform need not discover those CRDs during plan.
  # This dependency also removes the ingress before uninstalling its controller.
  depends_on = [helm_release.tailscale_operator]
}
