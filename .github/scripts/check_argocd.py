"""Render the actual pinned chart and reject public Argo CD exposure."""

from pathlib import Path
import re
import subprocess

import yaml


root = Path(__file__).resolve().parents[2]
terraform = (root / "terraform/bootstrap/main.tf").read_text()
release = terraform.split('resource "helm_release" "argocd" {', 1)[1]
version = re.search(r'version\s*=\s*"([^"]+)"', release).group(1)
rendered = subprocess.run(
    ["helm", "template", "argocd", "argo-cd", "--repo",
     "https://argoproj.github.io/argo-helm", "--version", version,
     "--namespace", "argocd", "--values", str(root / "terraform/bootstrap/values/argocd.yaml")],
    check=True, capture_output=True, text=True,
).stdout
objects = [obj for obj in yaml.safe_load_all(rendered) if obj]


def require(condition, message):
    if not condition:
        raise SystemExit(message)


for obj in objects:
    spec = obj.get("spec", {})
    if obj["kind"] == "Service":
        require(spec.get("type", "ClusterIP") == "ClusterIP", "Non-private Service")
        require(not spec.get("externalIPs"), "Service has external IPs")
    if obj["kind"] in {"Deployment", "StatefulSet", "DaemonSet", "Job"}:
        pod = spec["template"]["spec"]
        require(not pod.get("hostNetwork"), "Workload uses host networking")
        for container in pod.get("containers", []) + pod.get("initContainers", []):
            require(not any(p.get("hostPort") for p in container.get("ports", [])),
                    "Workload exposes a host port")
    require(obj["kind"] not in {"Gateway", "HTTPRoute", "GRPCRoute"},
            "Unexpected additional ingress route")

ingresses = [obj for obj in objects if obj["kind"] == "Ingress"]
require(len(ingresses) == 1, "Expected exactly one private Ingress")
ingress = ingresses[0]
require(ingress["spec"]["ingressClassName"] == "tailscale", "Wrong ingress controller")
require(ingress["metadata"]["annotations"].get("tailscale.com/funnel") == "false",
        "Funnel must be disabled")
group_name = ingress["metadata"]["annotations"]["tailscale.com/proxy-group"]
require(any(obj["kind"] == "ProxyGroup" and obj["metadata"]["name"] == group_name
            and obj["spec"]["type"] == "ingress" for obj in objects),
        "Ingress must reference an ingress ProxyGroup for a Tailscale Service")
backend = ingress["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"]
require(any(obj["kind"] == "Service" and obj["metadata"]["name"] == backend["name"]
            and any(port["port"] == backend["port"]["number"]
                    for port in obj["spec"]["ports"]) for obj in objects),
        "Ingress backend Service/port does not exist")
params = next(obj for obj in objects if obj["kind"] == "ConfigMap"
              and obj["metadata"]["name"] == "argocd-cmd-params-cm")
require(params["data"]["server.insecure"] == "true", "Backend must accept proxy HTTP")
print(f"Argo CD {version}: private Services, Tailscale HTTPS ingress and backend verified.")
