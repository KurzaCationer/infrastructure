#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/kurza-infrastructure.yaml}"
SYSTEM_NAMESPACE="${SYSTEM_NAMESPACE:-kube-system}"
GATEWAY_CLASS="${GATEWAY_CLASS:-cilium}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30s}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"

command -v kubectl >/dev/null 2>&1 || { echo 'Required command not found: kubectl' >&2; exit 1; }
if [[ ! -s "$KUBECONFIG_PATH" ]]; then
  bash "$SCRIPT_DIR/get-kubeconfig.sh"
fi

k() {
  kubectl --kubeconfig="$KUBECONFIG_PATH" --request-timeout="$REQUEST_TIMEOUT" "$@"
}

printf 'Checking cluster using %s\n' "$KUBECONFIG_PATH"
k cluster-info
k get nodes -o wide
k get pods -A
k wait nodes --all --for=condition=Ready --timeout="$ROLLOUT_TIMEOUT"
k rollout status -n "$SYSTEM_NAMESPACE" daemonset/cilium --timeout="$ROLLOUT_TIMEOUT"
k rollout status -n "$SYSTEM_NAMESPACE" deployment/cilium-operator --timeout="$ROLLOUT_TIMEOUT"
k wait gatewayclass "$GATEWAY_CLASS" --for=condition=Accepted --timeout="$ROLLOUT_TIMEOUT"

for namespace in sm-operator-system tailscale argocd cert-manager external-dns cnpg-system pocket-id; do
  k wait deployment -n "$namespace" --all --for=condition=Available --timeout="$ROLLOUT_TIMEOUT"
done
k rollout status -n argocd statefulset/argocd-application-controller --timeout="$ROLLOUT_TIMEOUT"
k get applications -n argocd
k wait applications -n argocd --all --for=jsonpath='{.status.sync.status}'=Synced --timeout="$ROLLOUT_TIMEOUT"
k wait applications -n argocd --all --for=jsonpath='{.status.health.status}'=Healthy --timeout="$ROLLOUT_TIMEOUT"
k wait certificates -n public-ingress --all --for=condition=Ready --timeout="$ROLLOUT_TIMEOUT"
k wait gateway/public -n public-ingress --for=condition=Programmed --timeout="$ROLLOUT_TIMEOUT"
k get ingress -n argocd
k get httproutes -A

printf '\nCluster checks passed.\nexport KUBECONFIG=%q\n' "$KUBECONFIG_PATH"
