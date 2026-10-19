# Hetzner image builds

For first-time setup, credentials, build commands and deployment order, use the
[root README's image-build step](../../../README.md#5-build-the-hetzner-base-images).
It covers both the **Hetzner Cloud Initialization** GitHub workflow and local builds.

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

## Bundle maintenance

Keep the templates, keys, verification scripts and manifest aligned with the module
version in [`../main.tf`](../main.tf). Preserve the full bundle, including the
legacy template, so all manifest entries stay verifiable. The manifest's exact
file list is enforced by `scripts/install-packer-security-bundle.sh`.

From this directory, verify local integrity without creating Hetzner resources:

```sh
sha256sum --check security-bundle.sha256
```

Signing keys and artifact hashes can expire or change. Update the reviewed bundle
and its manifest together; do not bypass verification. After a bundle update,
complete a real snapshot build and boot test before using it for a cluster.
