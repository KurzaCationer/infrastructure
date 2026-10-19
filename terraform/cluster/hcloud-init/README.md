# Hetzner project initialization

Build Leap Micro snapshots for x86 and ARM before the cluster's first apply.
This directory contains the unmodified Packer security bundle from
[Kube-Hetzner v3.2.1](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/tree/v3.2.1/packer-template).
The upstream license is included in `LICENSE.kube-hetzner`.

## Manual GitHub workflow

In Actions, select **Hcloud init > Run workflow** on the default branch, then
choose **both**, **x86**, or **arm**. The workflow has only a `workflow_dispatch`
trigger: pushes, pull requests, schedules, and the Terraform deployment workflow
never start it. Builds are serialized and an active build is not cancelled by a
new run.

It reuses `BWS_ACCESS_TOKEN` and the `hcloud_token` entry in `BW_SECRET_IDS`
from the existing repository settings. Optional `BW_API_URL`
and `BW_IDENTITY_API_URL` settings also apply. It needs neither AWS credentials
nor an existing cluster or S3 state.

The Bitwarden GitHub Action retrieves only the Hetzner token and exposes it as
a masked `HCLOUD_TOKEN` environment variable for Packer. This workflow does not
run Terraform or write Terraform state. The cluster deployment continues to use
the Terraform Bitwarden provider. The workflow installs the required Packer
version and calls the same `build.sh` used locally. A manual run builds billable
Hetzner snapshots; adding this workflow does not run a build.

## Local build

Use Linux, WSL, or macOS with Bash, Packer **1.16.0**, `curl`, `unzip`, and
`sha256sum` installed. On macOS, GNU coreutils provides `sha256sum`.

1. Create the Hetzner Cloud project and a project Read & Write API token.
2. Export that token as `HCLOUD_TOKEN` in your local shell. Use the same project
   whose token is stored in Bitwarden for Terraform. Do not commit the token.
3. From this directory, run:

```sh
bash build.sh
```

The wrapper checks the vendored files, installs the upstream hash-verified hcloud
Packer plugin, validates the template, then builds **x86 and ARM / k3s**. It creates
temporary build servers, removes them on a successful build, and retains billable
snapshots. It does not run automatically on each Terraform deployment.

The default build servers are `cx23` in `nbg1` (x86) and `cax11` in `fsn1` (ARM).
To build just one architecture or change build capacity, pass Packer options:

```sh
bash build.sh -only=hcloud.leapmicro-x86-snapshot -var=x86_server_type=cpx31 -var=x86_location=fsn1
bash build.sh -only=hcloud.leapmicro-arm-snapshot
```

Terraform selects ARM for `cax` server types and x86 for other types, discovering
the newest matching snapshot using this template's labels. Change `server_type`
in the cluster layer to select the node architecture. Run the build again when
deliberately refreshing the base image. Rebuilding does not update or replace
existing cluster nodes automatically.

Both upstream templates and all verification files are retained so
`security-bundle.sha256` stays verifiable. The wrapper does not build the legacy
MicroOS image. Keep the bundle aligned with the module version in
`../main.tf` when upgrading. Upstream signing keys and artifact hashes can expire
or change: update the reviewed bundle rather than bypassing its verification.
