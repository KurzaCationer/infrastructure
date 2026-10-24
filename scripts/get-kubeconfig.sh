#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY="${REPOSITORY:-KurzaCationer/infrastructure}"
CLUSTER_DIR="${CLUSTER_DIR:-$SCRIPT_ROOT/terraform/cluster}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/kurza-infrastructure.yaml}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"
AWS_REGION="${AWS_REGION:-}"

for tool in terraform kubectl; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'Required command not found: %s\n' "$tool" >&2; exit 1; }
done
if [[ -z "$TF_STATE_BUCKET" || -z "$AWS_REGION" ]]; then
  command -v gh >/dev/null 2>&1 || {
    echo 'Install/authenticate gh, or set both TF_STATE_BUCKET and AWS_REGION.' >&2
    exit 1
  }
fi
if [[ -z "$TF_STATE_BUCKET" ]]; then
  TF_STATE_BUCKET="$(gh variable get TF_STATE_BUCKET --repo "$REPOSITORY" --json value --jq .value)"
fi
if [[ -z "$AWS_REGION" ]]; then
  AWS_REGION="$(gh variable get AWS_REGION --repo "$REPOSITORY" --json value --jq .value)"
fi
: "${TF_STATE_BUCKET:?TF_STATE_BUCKET must not be empty.}"
: "${AWS_REGION:?AWS_REGION must not be empty.}"

terraform -chdir="$CLUSTER_DIR" init -reconfigure -input=false \
  "-backend-config=bucket=$TF_STATE_BUCKET" "-backend-config=region=$AWS_REGION"

mkdir -p -- "$(dirname -- "$KUBECONFIG_PATH")"
kubeconfig_tmp="$(mktemp "$KUBECONFIG_PATH.XXXXXX")"
trap 'rm -f -- "$kubeconfig_tmp"' EXIT
terraform -chdir="$CLUSTER_DIR" output -raw kubeconfig > "$kubeconfig_tmp"
[[ -s "$kubeconfig_tmp" ]] || { echo 'Empty kubeconfig returned from state.' >&2; exit 1; }
server="$(kubectl --kubeconfig="$kubeconfig_tmp" config view --minify -o 'jsonpath={.clusters[0].cluster.server}')"
[[ -n "$server" ]] || { echo 'Kubeconfig has no current cluster server.' >&2; exit 1; }
mv -f -- "$kubeconfig_tmp" "$KUBECONFIG_PATH"

printf 'Kubeconfig saved to %s\nAPI server: %s\n' "$KUBECONFIG_PATH" "$server"
printf 'export KUBECONFIG=%q\n' "$KUBECONFIG_PATH"
