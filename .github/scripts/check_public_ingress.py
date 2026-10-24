"""Validate the app-of-apps, public routing, and rendered platform charts."""

import argparse
from os.path import relpath
from pathlib import Path
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--external-dns-chart", help="Downloaded chart for offline validation")
parser.add_argument("--cloudnative-pg-chart", help="Downloaded chart for offline validation")
args = parser.parse_args()


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def build(path, patches=None):
    with tempfile.TemporaryDirectory() as directory:
        overlay = Path(directory) / "kustomization.yaml"
        overlay.write_text(yaml.safe_dump({
            "apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization",
            "resources": [Path(relpath(path, directory)).as_posix()], "patches": patches or [],
        }))
        rendered = subprocess.check_output([
            "kubectl", "kustomize", directory, "--load-restrictor=LoadRestrictionsNone",
        ], text=True)
    return [obj for obj in yaml.safe_load_all(rendered) if obj]


seed = (root / "terraform/bootstrap/values/root-application.yaml.tftpl").read_text()
seed = yaml.safe_load(seed.replace("${organization_id}", "00000000-0000-0000-0000-000000000001")
                      .replace("${pocket_id_encryption_key_secret_id}", "00000000-0000-0000-0000-000000000004")
                      .replace("${pocket_id_api_key_secret_id}", "00000000-0000-0000-0000-000000000005")
                      .replace("${public_ipv4}", "192.0.2.10"))
require(seed["spec"]["source"]["path"] == "argocd", "Root must watch argocd/")
apps = build(root / "argocd", seed["spec"]["source"]["kustomize"]["patches"])
unconfigured_pocket = next(app for app in build(root / "argocd")
                           if app["metadata"]["name"] == "pocket-id")
require(unconfigured_pocket["spec"]["syncPolicy"]["automated"]["enabled"] is False,
        "Pocket ID must not auto-sync placeholders before bootstrap injects its UUIDs")
require({app["metadata"]["name"] for app in apps} == {
    "public-ingress", "external-dns", "https-test", "cloudnative-pg", "quad-assignment", "pocket-id",
}, "Unexpected child apps, or duplicate cert-manager installation")
quad = next(app for app in apps if app["metadata"]["name"] == "quad-assignment")
require(quad["spec"]["source"] == {
    "repoURL": "https://github.com/KurzaCationer/quad-assignment.git",
    "targetRevision": "main",
    "path": "deploy/overlays/production",
}, "Quad must deploy the production overlay from its own repository's main branch")
require(quad["spec"]["destination"] == {
    "server": "https://kubernetes.default.svc", "namespace": "quad-assignment",
}, "Quad must target its own namespace on this cluster")
require(quad["spec"]["syncPolicy"]["automated"] == {"prune": False, "selfHeal": True},
        "Quad must self-heal without automatically pruning database resources")
require("ServerSideApply=true" in quad["spec"]["syncPolicy"]["syncOptions"],
        "Quad must use server-side apply")
require(not quad["metadata"].get("finalizers"), "Deleting Quad's Application must not cascade to its database")
objects = []
for app in apps:
    spec = app["spec"]
    if "source" in spec:
        source = spec["source"]
        # The external assignment overlay is validated in its own repository's CI.
        if app["metadata"]["name"] == "quad-assignment":
            continue
        require(source["repoURL"] == seed["spec"]["source"]["repoURL"],
                "Local manifest validation requires an infrastructure repository source")
        objects += build(root / source["path"], source.get("kustomize", {}).get("patches"))

mappings = [obj for obj in objects if obj["kind"] == "BitwardenSecret"]
require({obj["metadata"]["namespace"] for obj in mappings} == {"cert-manager", "external-dns", "pocket-id"},
        "Cloudflare and Pocket ID credentials must be namespace-local")
for obj in mappings:
    require(obj["spec"]["organizationId"] == "00000000-0000-0000-0000-000000000001",
            "Root did not propagate the organization UUID")
    require(obj["spec"]["onlyMappedSecrets"] is True, "BWS must sync only explicitly mapped secrets")
    require(obj["spec"]["authToken"] == {"secretName": "bitwarden-auth", "secretKey": "token"},
            "BWS must reuse the existing operator credentials")
certs = [obj for obj in objects if obj["kind"] == "Certificate"]
pocket_app = next(app for app in apps if app["metadata"]["name"] == "pocket-id")
require(pocket_app["spec"]["syncPolicy"]["automated"]["enabled"] is True,
        "Bootstrap must enable Pocket ID auto-sync together with its UUID patches")
require(pocket_app["spec"]["syncPolicy"]["automated"]["prune"] is False
        and not pocket_app["metadata"].get("finalizers"),
        "Pocket ID removal must not cascade to its persistent data")
pocket_mapping = next(obj for obj in mappings if obj["metadata"]["namespace"] == "pocket-id")
require(pocket_mapping["spec"]["map"] == [
    {"bwSecretId": "00000000-0000-0000-0000-000000000004", "secretKeyName": "encryption-key"},
    {"bwSecretId": "00000000-0000-0000-0000-000000000005", "secretKeyName": "api-key"},
], "Root must propagate both generated Pocket ID secret UUIDs")
pocket_pvc = next(obj for obj in objects if obj["kind"] == "PersistentVolumeClaim")
require(pocket_pvc["spec"]["storageClassName"] == "hcloud-volumes"
        and pocket_pvc["metadata"]["annotations"]["argocd.argoproj.io/sync-options"] == "Prune=false,Delete=false",
        "Pocket ID must use persistent block storage protected from GitOps deletion")
pocket_deployment = next(obj for obj in objects if obj["kind"] == "Deployment"
                         and obj["metadata"]["name"] == "pocket-id")
require(pocket_deployment["spec"]["replicas"] == 1
        and pocket_deployment["spec"]["strategy"]["type"] == "Recreate",
        "SQLite must have a single writer during updates")
pocket_route = next(obj for obj in objects if obj["kind"] == "HTTPRoute"
                   and obj["metadata"]["name"] == "pocket-id")
require(pocket_route["spec"]["hostnames"] == ["auth.kurza.nl"]
        and pocket_route["spec"]["parentRefs"][0]["sectionName"] == "kurza-nl-https",
        "Pocket ID must use its canonical HTTPS hostname")
require({name for cert in certs for name in cert["spec"]["dnsNames"]} == {
    "*.dylannas.nl", "*.kurza.nl",
}, "Incorrect wildcard coverage")
gateway = next(obj for obj in objects if obj["kind"] == "Gateway")
require(gateway["metadata"]["annotations"]["external-dns.kubernetes.io/target"] == "192.0.2.10",
        "Root must propagate the public origin IP instead of private Gateway status addresses")
for listener in gateway["spec"]["listeners"]:
    if listener["protocol"] == "HTTPS":
        require(listener["port"] == 443 and listener["tls"]["mode"] == "Terminate", "Incorrect TLS listener")
        require(listener["tls"]["certificateRefs"][0]["name"] in {cert["spec"]["secretName"] for cert in certs},
                "Gateway references a missing certificate")
route = next(obj for obj in objects if obj["kind"] == "HTTPRoute" and obj["metadata"]["name"] == "https-test")
require(route["spec"]["hostnames"] == ["test.kurza.nl"], "Test app must publish only its own hostname")
require(route["spec"]["parentRefs"][0]["sectionName"] == "kurza-nl-https", "Test must use HTTPS")
require(all(obj["spec"].get("type", "ClusterIP") == "ClusterIP" for obj in objects if obj["kind"] == "Service"),
        "Application Services must remain internal")

app = next(app for app in apps if app["metadata"]["name"] == "external-dns")
source = app["spec"]["sources"][0]
chart_args = [args.external_dns_chart] if args.external_dns_chart else [
    source["chart"], "--repo", source["repoURL"], "--version", source["targetRevision"],
]
rendered = subprocess.check_output([
    "helm", "template", "external-dns", *chart_args, "--namespace", "external-dns",
    "--values", str(root / "argocd/values/external-dns.yaml"),
], text=True)
dns = [obj for obj in yaml.safe_load_all(rendered) if obj]
container = next(obj for obj in dns if obj["kind"] == "Deployment")["spec"]["template"]["spec"]["containers"][0]
flags = container["args"]
for flag in ("--source=gateway-httproute", "--provider=cloudflare", "--cloudflare-proxied",
             "--domain-filter=dylannas.nl", "--domain-filter=kurza.nl", "--registry=txt",
             "--txt-owner-id=kurza-infrastructure", "--policy=upsert-only",
             "--label-filter=infrastructure.kurza.nl/public-dns=true", "--gateway-namespace=public-ingress"):
    require(flag in flags, f"Missing DNS boundary: {flag}")
require([flag for flag in flags if flag.startswith("--source=")] == ["--source=gateway-httproute"],
        "Do not publish private Tailscale ingress or Services")
require(next(env for env in container["env"] if env["name"] == "CF_API_TOKEN")["valueFrom"] == {
    "secretKeyRef": {"name": "cloudflare-api-token", "key": "api-token"},
}, "ExternalDNS must read its token from BWS")
app = next(app for app in apps if app["metadata"]["name"] == "cloudnative-pg")
require(app["spec"]["destination"]["namespace"] == "cnpg-system", "CNPG must use its own namespace")
require({"CreateNamespace=true", "ServerSideApply=true"}.issubset(app["spec"]["syncPolicy"]["syncOptions"]),
        "CNPG requires namespace creation and server-side apply for its CRDs")
source = app["spec"]["sources"][0]
chart_args = [args.cloudnative_pg_chart] if args.cloudnative_pg_chart else [
    source["chart"], "--repo", source["repoURL"], "--version", source["targetRevision"],
]
rendered = subprocess.check_output([
    "helm", "template", "cloudnative-pg", *chart_args, "--namespace", "cnpg-system",
    "--values", str(root / "argocd/values/cloudnative-pg.yaml"),
], text=True)
cnpg = [obj for obj in yaml.safe_load_all(rendered) if obj]
require(any(obj["kind"] == "CustomResourceDefinition" and
            obj["metadata"]["name"] == "clusters.postgresql.cnpg.io" for obj in cnpg),
        "CNPG must install its database cluster CRD")
operator = next(obj for obj in cnpg if obj["kind"] == "Deployment")
require(operator["spec"]["replicas"] == 1, "Use one CNPG operator replica on this single-node cluster")
require(any(obj["kind"] == "ClusterRoleBinding" for obj in cnpg), "CNPG requires cluster-wide RBAC")
require(all(obj["spec"].get("type", "ClusterIP") == "ClusterIP" for obj in cnpg if obj["kind"] == "Service"),
        "CNPG Services must remain internal")
require(not any(obj["kind"] in {"Cluster", "Database", "Ingress", "HTTPRoute", "ServiceMonitor", "PodMonitor"}
                for obj in cnpg), "Install only the operator, without databases, public routes or monitoring dependencies")
print("App-of-apps, BWS references, wildcard TLS, public DNS and CloudNativePG checks passed.")
