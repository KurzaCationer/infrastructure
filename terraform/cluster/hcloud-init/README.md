# Hetzner image builds

Prerequisites and deployment order: [setup](../../../docs/setup.md#5-build-the-hetzner-base-images).

This directory vendors the Packer security bundle from
[Kube-Hetzner v3.2.1](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/tree/v3.2.1/packer-template).
The upstream license is included in [`LICENSE.kube-hetzner`](LICENSE.kube-hetzner).

| Path | Purpose |
| --- | --- |
| [`build.sh`](build.sh) | Verifies bundle hashes, installs the verified hcloud plugin, validates and builds Leap Micro snapshots for k3s |
| [`hcloud-leapmicro-snapshots.pkr.hcl`](hcloud-leapmicro-snapshots.pkr.hcl) | Active x86/ARM image template |
| [`hcloud-microos-snapshots.pkr.hcl`](hcloud-microos-snapshots.pkr.hcl) | Legacy upstream template, retained for bundle integrity; not built by the wrapper |
| [`security-bundle.sha256`](security-bundle.sha256) | Exact manifest of vendored templates, keys and verification scripts |
| [`keys/`](keys/README.md) | Public signing keys and trust-anchor maintenance notes |
| [`scripts/`](scripts/) | Upstream plugin installation, image and RPM verification helpers |

Terraform selects ARM snapshots for `cax` server types and x86 for other types,
using the newest matching snapshot labels. Rebuilding images does not update or
replace existing nodes. Temporary build servers and retained snapshots are billable.

## Build commands

Run commands from the repository root. Install Packer **1.16.0**, export `HCLOUD_TOKEN`, and run:

```sh
bash terraform/cluster/hcloud-init/build.sh
```

Alternatively, manually run **Hetzner Cloud Initialization** in GitHub Actions and select x86,
ARM, or both. It retrieves the Hetzner token using the Bitwarden GitHub Action
and the existing repository settings. It is never triggered automatically.

The image builds create temporary servers and billable snapshots in Hetzner.
Image builds run separately from Terraform deployments and do not require a
Terraform module download.

The default cluster needs an x86 snapshot; `cax` server types need ARM. The local
wrapper builds both architectures unless you select one:

```sh
bash terraform/cluster/hcloud-init/build.sh -only=hcloud.leapmicro-x86-snapshot
bash terraform/cluster/hcloud-init/build.sh -only=hcloud.leapmicro-arm-snapshot
```

Default build servers are `cx23` in `nbg1` (x86) and `cax11` in `fsn1` (ARM).
Build capacity and location overrides:

```sh
bash terraform/cluster/hcloud-init/build.sh -only=hcloud.leapmicro-x86-snapshot -var=x86_server_type=cpx31 -var=x86_location=fsn1
```

The wrapper verifies the vendored bundle, installs the hash-verified hcloud Packer
plugin, validates the Leap Micro template and builds k3s snapshots. The legacy
MicroOS template remains for bundle integrity but is not built by the wrapper.
Successful builds remove temporary servers; inspect the Hetzner project after a
failed build. Rebuilding snapshots does not update or replace existing nodes.

## Bundle maintenance

Keep the templates, keys, verification scripts and manifest aligned with the module
version in [`../main.tf`](../main.tf). Preserve the full bundle, including the
legacy template, so all manifest entries stay verifiable. The manifest's exact
file list is enforced by `scripts/install-packer-security-bundle.sh`.

From this directory, verify local integrity without creating Hetzner resources:

```sh
sha256sum --check security-bundle.sha256
```

Bundle updates include the signing keys, artifact hashes and manifest. A snapshot
build and boot test are required after an update.
