#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Configuration: edit defaults here, or override with environment variables.
# Names and defaults match check-cluster.bat. Blank backend values use GitHub.
REPOSITORY="${REPOSITORY:-KurzaCationer/infrastructure}"
CLUSTER_DIR="${CLUSTER_DIR:-$SCRIPT_ROOT/terraform/cluster}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"
AWS_REGION="${AWS_REGION:-}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/kurza-infrastructure.yaml}"
SYSTEM_NAMESPACE="${SYSTEM_NAMESPACE:-kube-system}"
GATEWAY_CLASS="${GATEWAY_CLASS:-cilium}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30s}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"

# Prerequisites and backend settings.

for tool in terraform tailscale kubectl; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'Required command not found: %s\n' "$tool" >&2; exit 1; }
done

if [[ -z "${TF_STATE_BUCKET:-}" || -z "${AWS_REGION:-}" ]]; then
  command -v gh >/dev/null 2>&1 || {
    echo 'Install/authenticate gh, or set both TF_STATE_BUCKET and AWS_REGION.' >&2
    exit 1
  }
fi
if [[ -z "${TF_STATE_BUCKET:-}" ]]; then
  TF_STATE_BUCKET="$(gh variable get TF_STATE_BUCKET --repo "$REPOSITORY" --json value --jq .value)"
fi
if [[ -z "${AWS_REGION:-}" ]]; then
  AWS_REGION="$(gh variable get AWS_REGION --repo "$REPOSITORY" --json value --jq .value)"
fi
: "${TF_STATE_BUCKET:?TF_STATE_BUCKET must not be empty.}"
: "${AWS_REGION:?AWS_REGION must not be empty.}"

echo 'Reading the shared Terraform state using your existing AWS credentials...'
terraform -chdir="$CLUSTER_DIR" init -reconfigure -input=false \
  "-backend-config=bucket=$TF_STATE_BUCKET" "-backend-config=region=$AWS_REGION"
terraform -chdir="$CLUSTER_DIR" state list
control_plane_host="$(terraform -chdir="$CLUSTER_DIR" output -raw control_plane_hostname)"
[[ -n "$control_plane_host" ]] || { echo 'No control-plane hostname found in state.' >&2; exit 1; }

# Write atomically so failed state access never overwrites an existing kubeconfig.
mkdir -p -- "$(dirname -- "$KUBECONFIG_PATH")"
kubeconfig_tmp="$(mktemp "$KUBECONFIG_PATH.XXXXXX")"
trap 'rm -f -- "$kubeconfig_tmp"' EXIT
terraform -chdir="$CLUSTER_DIR" output -raw kubeconfig > "$kubeconfig_tmp"
[[ -s "$kubeconfig_tmp" ]] || { echo 'Empty kubeconfig returned from state.' >&2; exit 1; }
mv -f -- "$kubeconfig_tmp" "$KUBECONFIG_PATH"

printf 'Kubeconfig saved to %s\nPrivate node: %s\n' "$KUBECONFIG_PATH" "$control_plane_host"
tailscale status
tailscale ping "$control_plane_host"

kubectl --kubeconfig="$KUBECONFIG_PATH" --request-timeout="$REQUEST_TIMEOUT" cluster-info
kubectl --kubeconfig="$KUBECONFIG_PATH" --request-timeout="$REQUEST_TIMEOUT" get nodes -o wide
kubectl --kubeconfig="$KUBECONFIG_PATH" --request-timeout="$REQUEST_TIMEOUT" get pods -A
kubectl --kubeconfig="$KUBECONFIG_PATH" -n "$SYSTEM_NAMESPACE" rollout status daemonset/cilium --timeout="$ROLLOUT_TIMEOUT"
kubectl --kubeconfig="$KUBECONFIG_PATH" -n "$SYSTEM_NAMESPACE" rollout status deployment/cilium-operator --timeout="$ROLLOUT_TIMEOUT"
kubectl --kubeconfig="$KUBECONFIG_PATH" --request-timeout="$REQUEST_TIMEOUT" get gatewayclass "$GATEWAY_CLASS"

printf '\nChecks completed. For subsequent kubectl commands, run:\nexport KUBECONFIG=%q\n' "$KUBECONFIG_PATH"
printf 'For SSH, use your deployment private key with: ssh root@%s\n' "$control_plane_host"
