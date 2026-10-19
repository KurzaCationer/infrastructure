#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
: "${HCLOUD_TOKEN:?Export the Hetzner project Read & Write API token as HCLOUD_TOKEN.}"

# Keep the complete upstream image verification bundle intact.
sha256sum --check security-bundle.sha256
bash scripts/install-verified-packer-plugin-hcloud.sh

# Prepare both architectures for k3s; pass -only to build just one if desired.
packer validate -var=selinux_package_to_install=k3s hcloud-leapmicro-snapshots.pkr.hcl
packer build -var=selinux_package_to_install=k3s "$@" hcloud-leapmicro-snapshots.pkr.hcl
