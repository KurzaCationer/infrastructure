# Hetzner images

Run **Hetzner Cloud Initialization** in GitHub Actions, selecting ARM for
`cax` nodes or x86 for other server types. The current default node requires ARM.

For local builds, install Packer **1.16.0**, Bash, `curl`, `unzip` and
`sha256sum`, then export `HCLOUD_TOKEN`. From the repository root:

```sh
bash terraform/cluster/hcloud-init/build.sh -only=hcloud.leapmicro-arm-snapshot
bash terraform/cluster/hcloud-init/build.sh -only=hcloud.leapmicro-x86-snapshot
```

Omit `-only` to build both. To override unavailable build capacity:

```sh
bash terraform/cluster/hcloud-init/build.sh -only=hcloud.leapmicro-x86-snapshot -var=x86_server_type=cpx31 -var=x86_location=fsn1
```

Build servers and snapshots are billable. Inspect the Hetzner project for
leftover servers after failed builds. Rebuilding images does not replace nodes.

## Bundle maintenance

The bundle is vendored from Kube-Hetzner v3.2.1; its license is in
[LICENSE.kube-hetzner](LICENSE.kube-hetzner).

Update templates, [signing keys](keys/README.md), verification scripts and
`security-bundle.sha256` together with the pinned module version.
Preserve the legacy MicroOS template for bundle verification.

From this directory:

```sh
sha256sum --check security-bundle.sha256
```

Complete a snapshot build and boot test before deploying an updated bundle.
