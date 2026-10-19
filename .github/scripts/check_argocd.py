"""Render the actual pinned chart and reject public Argo CD exposure."""

from pathlib import Path
import argparse
import re
import subprocess

import yaml


root = Path(__file__).resolve().parents[2]
terraform = (root / "terraform/bootstrap/main.tf").read_text()
release = terraform.split('resource "helm_release" "argocd" {', 1)[1]
version = re.search(r'version\s*=\s*"([^"]+)"', release).group(1)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--chart", help="Use a downloaded chart archive for offline validation")
args = parser.parse_args()
chart_args = [args.chart] if args.chart else [
    "argo-cd", "--repo", "https://argoproj.github.io/argo-helm", "--version", version,
]
rendered = subprocess.run(
    ["helm", "template", "argocd", *chart_args,
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

# A failed cleanup must block Helm before Terraform can uninstall the operator.
cleanup = next(obj for obj in objects if obj["kind"] == "Job"
               and obj["metadata"]["name"] == "argocd-tailscale-cleanup")
annotations = cleanup["metadata"]["annotations"]
require(annotations.get("helm.sh/hook") == "pre-delete", "Cleanup must precede uninstall")
require(annotations.get("helm.sh/hook-delete-policy") == "before-hook-creation,hook-succeeded",
        "Keep failed cleanup logs and allow retries")
require(cleanup["spec"]["backoffLimit"] == 0
        and cleanup["spec"]["activeDeadlineSeconds"] < 600,
        "Cleanup must fail within the Helm timeout")
pod = cleanup["spec"]["template"]["spec"]
steps = pod["initContainers"] + pod["containers"]
require(len(steps) == 3, "Expected three ordered cleanup steps")
for step, resource, name in zip(steps, ["ingress", "proxygroup.tailscale.com",
                                      "proxyclass.tailscale.com"],
                              [ingress["metadata"]["name"], group_name, group_name]):
    require(step["command"] == ["kubectl"] and step["args"][:3] == ["delete", resource, name],
            "Cleanup must delete ingress, then proxy group, then proxy class")
    require(all(flag in step["args"] for flag in ["--wait=true", "--ignore-not-found=true",
                                                 "--timeout=120s"]),
            "Cleanup must wait for finalizers and tolerate already deleted objects")
role = next(obj for obj in objects if obj["kind"] == "ClusterRole"
            and obj["metadata"]["name"] == pod["serviceAccountName"])
require(all(set(rule["verbs"]) == {"get", "list", "watch", "delete"}
            and rule.get("resourceNames") for rule in role["rules"]),
        "Cleanup permissions must be named deletes with no ability to strip finalizers")
print(f"Argo CD {version}: private ingress, backend and ordered teardown hook verified.")
