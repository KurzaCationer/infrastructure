/*
 * Creates a Leap Micro snapshot for Kube-Hetzner
 */
packer {
  required_version = "= 1.16.0"

  required_plugins {
    hcloud = {
      version = "= 1.7.2"
      source  = "github.com/hetznercloud/hcloud"
    }
  }
}

variable "hcloud_token" {
  type      = string
  default   = env("HCLOUD_TOKEN")
  sensitive = true
}

# Server type and location used to build each snapshot. Override these when the defaults are
# unavailable in your project (Hetzner availability varies by location and over time), e.g.:
#   packer build -var x86_server_type=cpx31 -var x86_location=fsn1 <template>.pkr.hcl
# To build only one architecture (e.g. no ARM capacity available), use -only with the
# corresponding source name. Any server type works as long as its disk is >= 40GiB.
variable "x86_server_type" {
  type    = string
  default = "cx23"
}

variable "x86_location" {
  type    = string
  default = "nbg1"
}

variable "arm_server_type" {
  type    = string
  default = "cax11"
}

variable "arm_location" {
  type    = string
  default = "fsn1"
}


variable "leap_micro_version" {
  type        = string
  default     = "6.2"
  description = "OpenSUSE Leap Micro version."

  validation {
    condition     = can(regex("^[0-9]+[.][0-9]+$", var.leap_micro_version))
    error_message = "The Leap Micro version must be a numeric major.minor value such as 6.2."
  }
}

variable "k3s_selinux_version" {
  type        = string
  default     = "v1.6.stable.1"
  description = "k3s-selinux release tag to install."

  validation {
    condition     = can(regex("^v[0-9]+[.][0-9]+[.](stable|latest|testing)[.][0-9]+$", var.k3s_selinux_version))
    error_message = "The k3s-selinux version must be a release tag such as v1.6.stable.1."
  }
}

variable "k3s_selinux_package_name" {
  type        = string
  default     = ""
  description = "Optional k3s-selinux RPM filename override. If empty, derived from tag using slemicro package form."

  validation {
    condition     = var.k3s_selinux_package_name == "" || can(regex("^k3s-selinux-[0-9]+[.][0-9]+-[0-9]+[.]slemicro[.]noarch[.]rpm$", var.k3s_selinux_package_name))
    error_message = "The k3s-selinux package override must be empty or a safe slemicro noarch RPM filename."
  }
}

variable "k3s_selinux_expected_sha256" {
  type        = string
  default     = ""
  description = "Optional SHA-256 override for the exact k3s-selinux RPM release asset."

  validation {
    condition     = var.k3s_selinux_expected_sha256 == "" || can(regex("^[0-9A-Fa-f]{64}$", var.k3s_selinux_expected_sha256))
    error_message = "The k3s-selinux RPM SHA-256 must be empty or exactly 64 hexadecimal characters."
  }
}

variable "rke2_selinux_version" {
  type        = string
  default     = "v0.22.stable.1"
  description = "rke2-selinux release tag to install."

  validation {
    condition     = can(regex("^v[0-9]+[.][0-9]+[.](stable|latest|testing)[.][0-9]+$", var.rke2_selinux_version))
    error_message = "The rke2-selinux version must be a release tag such as v0.22.stable.1."
  }
}

variable "rke2_selinux_package_name" {
  type        = string
  default     = ""
  description = "Optional rke2-selinux RPM filename override. If empty, derived from tag using slemicro package form."

  validation {
    condition     = var.rke2_selinux_package_name == "" || can(regex("^rke2-selinux-[0-9]+[.][0-9]+-[0-9]+[.]slemicro[.]noarch[.]rpm$", var.rke2_selinux_package_name))
    error_message = "The rke2-selinux package override must be empty or a safe slemicro noarch RPM filename."
  }
}

variable "rke2_selinux_expected_sha256" {
  type        = string
  default     = ""
  description = "Optional SHA-256 override for the exact rke2-selinux RPM release asset."

  validation {
    condition     = var.rke2_selinux_expected_sha256 == "" || can(regex("^[0-9A-Fa-f]{64}$", var.rke2_selinux_expected_sha256))
    error_message = "The rke2-selinux RPM SHA-256 must be empty or exactly 64 hexadecimal characters."
  }
}

variable "selinux_package_to_install" {
  type        = string
  default     = "k3s"
  description = "Which Kubernetes SELinux package variant to preinstall in the snapshot: k3s or rke2."

  validation {
    condition     = contains(["k3s", "rke2"], var.selinux_package_to_install)
    error_message = "The SELinux package variant must be either k3s or rke2."
  }
}

# We download the OpenSUSE Leap Micro x86 image from an automatically selected mirror.
variable "opensuse_leapmicro_x86_mirror_link" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional custom x86 appliance URL. Custom mirrors also require signed sidecar URLs and an independently pinned SHA-256 digest."

}

variable "opensuse_leapmicro_x86_checksum_link" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional explicit x86 SHA-256 sidecar URL. Required with signature_link for query-bearing image URLs."
}

variable "opensuse_leapmicro_x86_signature_link" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional explicit x86 detached-signature sidecar URL. Required with checksum_link for query-bearing image URLs."
}

variable "opensuse_leapmicro_x86_expected_sha256" {
  type        = string
  default     = ""
  description = "Optional x86 SHA-256 override. Required for versions without a built-in reviewed digest and for custom mirrors."

  validation {
    condition     = var.opensuse_leapmicro_x86_expected_sha256 == "" || can(regex("^[0-9A-Fa-f]{64}$", var.opensuse_leapmicro_x86_expected_sha256))
    error_message = "The x86 custom image SHA-256 must be empty or exactly 64 hexadecimal characters."
  }
}

# We download the OpenSUSE Leap Micro ARM image from an automatically selected mirror.
variable "opensuse_leapmicro_arm_mirror_link" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional custom ARM appliance URL. Custom mirrors also require signed sidecar URLs and an independently pinned SHA-256 digest."

}

variable "opensuse_leapmicro_arm_checksum_link" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional explicit ARM SHA-256 sidecar URL. Required with signature_link for query-bearing image URLs."
}

variable "opensuse_leapmicro_arm_signature_link" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional explicit ARM detached-signature sidecar URL. Required with checksum_link for query-bearing image URLs."
}

variable "opensuse_leapmicro_arm_expected_sha256" {
  type        = string
  default     = ""
  description = "Optional ARM SHA-256 override. Required for versions without a built-in reviewed digest and for custom mirrors."

  validation {
    condition     = var.opensuse_leapmicro_arm_expected_sha256 == "" || can(regex("^[0-9A-Fa-f]{64}$", var.opensuse_leapmicro_arm_expected_sha256))
    error_message = "The ARM custom image SHA-256 must be empty or exactly 64 hexadecimal characters."
  }
}

variable "opensuse_leapmicro_x86_mirror_authorization_header" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional Authorization header for x86 custom URLs. When set, image and sidecars must share one HTTPS origin; custom redirects are always rejected."
}

variable "opensuse_leapmicro_arm_mirror_authorization_header" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional Authorization header for ARM custom URLs. When set, image and sidecars must share one HTTPS origin; custom redirects are always rejected."
}

# If you need to add other packages to the OS, do it here in the default value, like ["vim", "curl", "wget"].
variable "packages_to_install" {
  type    = list(string)
  default = []
}

# Timezone to set on the snapshot (e.g., "Europe/Madrid", "UTC", "America/New_York").
variable "timezone" {
  type    = string
  default = "UTC"

  validation {
    condition     = can(regex("^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$", var.timezone))
    error_message = "The timezone must be a safe relative zoneinfo name such as UTC or Europe/Madrid."
  }
}

# Path to a local file containing sysctl settings (one per line, e.g., "vm.swappiness = 10").
# These will be installed to /etc/sysctl.d/99-custom.conf
variable "sysctl_config_file" {
  type    = string
  default = ""
}

locals {
  snapshot_build_timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())
  snapshot_build_id        = substr(replace(uuidv4(), "-", ""), 0, 12)

  opensuse_leapmicro_x86_mirror_link_computed    = var.opensuse_leapmicro_x86_mirror_link != "" ? var.opensuse_leapmicro_x86_mirror_link : "https://download.opensuse.org/distribution/leap-micro/${var.leap_micro_version}/appliances/openSUSE-Leap-Micro.x86_64-Default-qcow.qcow2"
  opensuse_leapmicro_arm_mirror_link_computed    = var.opensuse_leapmicro_arm_mirror_link != "" ? var.opensuse_leapmicro_arm_mirror_link : "https://download.opensuse.org/distribution/leap-micro/${var.leap_micro_version}/appliances/openSUSE-Leap-Micro.aarch64-Default-qcow.qcow2"
  opensuse_leapmicro_x86_checksum_link_computed  = var.opensuse_leapmicro_x86_checksum_link != "" ? var.opensuse_leapmicro_x86_checksum_link : "${local.opensuse_leapmicro_x86_mirror_link_computed}.sha256"
  opensuse_leapmicro_x86_signature_link_computed = var.opensuse_leapmicro_x86_signature_link != "" ? var.opensuse_leapmicro_x86_signature_link : "${local.opensuse_leapmicro_x86_mirror_link_computed}.sha256.asc"
  opensuse_leapmicro_arm_checksum_link_computed  = var.opensuse_leapmicro_arm_checksum_link != "" ? var.opensuse_leapmicro_arm_checksum_link : "${local.opensuse_leapmicro_arm_mirror_link_computed}.sha256"
  opensuse_leapmicro_arm_signature_link_computed = var.opensuse_leapmicro_arm_signature_link != "" ? var.opensuse_leapmicro_arm_signature_link : "${local.opensuse_leapmicro_arm_mirror_link_computed}.sha256.asc"
  # Exact-byte pins make publisher-signed alias rollback fail closed. When
  # openSUSE refreshes an alias, review the new signed checksum before updating.
  opensuse_leapmicro_reviewed_x86_sha256 = {
    "6.1" = "5988121f99870359ad3ed5d441dc5ea59a1d89dfda8bda355798940e6fab8f7d"
    "6.2" = "7e8d63179afbc4e6c6573e572ffb00ad1d1da4a3ba021bbc8d4ef1cb686d019f"
  }
  opensuse_leapmicro_reviewed_arm_sha256 = {
    "6.1" = "951615102bd54e76242d7ef26dae3c324cdb7243b360e2022d2f34d6706a6ef2"
    "6.2" = "7eee4cdd7c87218ed1c6630ec3c4349593655dcf9b7d44f01df7b4323971ba9d"
  }
  opensuse_leapmicro_x86_expected_sha256_computed = var.opensuse_leapmicro_x86_mirror_link != "" ? lower(var.opensuse_leapmicro_x86_expected_sha256) : var.opensuse_leapmicro_x86_expected_sha256 != "" ? lower(var.opensuse_leapmicro_x86_expected_sha256) : lookup(local.opensuse_leapmicro_reviewed_x86_sha256, var.leap_micro_version, "")
  opensuse_leapmicro_arm_expected_sha256_computed = var.opensuse_leapmicro_arm_mirror_link != "" ? lower(var.opensuse_leapmicro_arm_expected_sha256) : var.opensuse_leapmicro_arm_expected_sha256 != "" ? lower(var.opensuse_leapmicro_arm_expected_sha256) : lookup(local.opensuse_leapmicro_reviewed_arm_sha256, var.leap_micro_version, "")

  rancher_reviewed_k3s_selinux_sha256 = {
    "v1.6.stable.1" = "583f4b3d5f838e9e2bb450f7cc60142de15fc2deaa56687d15b07a73b80b8836"
  }
  rancher_reviewed_rke2_selinux_sha256 = {
    "v0.22.stable.1" = "f3eee9e2e27e4771e4a25b5107f0f762260df0a1f1a1081c14993e6e1a916301"
  }
  k3s_selinux_expected_sha256_computed  = var.k3s_selinux_expected_sha256 != "" ? lower(var.k3s_selinux_expected_sha256) : lookup(local.rancher_reviewed_k3s_selinux_sha256, var.k3s_selinux_version, "")
  rke2_selinux_expected_sha256_computed = var.rke2_selinux_expected_sha256 != "" ? lower(var.rke2_selinux_expected_sha256) : lookup(local.rancher_reviewed_rke2_selinux_sha256, var.rke2_selinux_version, "")

  # Trust anchors are reviewed and vendored so signature verification remains
  # available to air-gapped builders and cannot silently follow a remote key.
  opensuse_signing_key_fingerprint  = "AD485664E901B867051AB15F35A2F86E29B700A4"
  rancher_signing_key_fingerprint   = "C8CFF216455126E9B9C918BE925EA29AE257814A"
  opensuse_signing_key_base64       = filebase64("${path.root}/keys/opensuse-project-signing-key.asc")
  rancher_signing_key_base64        = filebase64("${path.root}/keys/rancher-ci-signing-key.asc")
  image_verifier_base64             = filebase64("${path.root}/scripts/verify-leapmicro-image.sh")
  rancher_rpm_installer_base64      = filebase64("${path.root}/scripts/install-verified-rancher-rpm.sh")
  rancher_rpm_verifier_base64       = filebase64("${path.root}/scripts/verify-rancher-rpm.sh")
  opensuse_leapmicro_x86_image_path = "/root/openSUSE-Leap-Micro.x86_64-Default-qcow.qcow2"
  opensuse_leapmicro_arm_image_path = "/root/openSUSE-Leap-Micro.aarch64-Default-qcow.qcow2"

  # Keep this list minimal and known-good on Leap Micro (some MicroOS package names are not available).
  needed_packages = join(" ", concat(["restorecond", "policycoreutils", "policycoreutils-python-utils", "selinux-policy", "checkpolicy", "audit", "open-iscsi", "nfs-client", "xfsprogs", "cryptsetup", "lvm2", "git", "cifs-utils", "bash-completion", "udica", "qemu-guest-agent"], var.packages_to_install))

  # Read sysctl config if file path is provided, otherwise empty (base64 encoded for safe transfer)
  sysctl_config_content = var.sysctl_config_file != "" ? base64encode(file(var.sysctl_config_file)) : ""

  # Commands to write sysctl config if provided (decode base64)
  sysctl_commands = local.sysctl_config_content != "" ? "echo '${local.sysctl_config_content}' | base64 -d > /etc/sysctl.d/99-custom.conf" : ""

  download_and_verify_image = <<-EOT
    set -eu
    umask 077
    printf '%s' '${local.image_verifier_base64}' | base64 -d > /tmp/verify-leapmicro-image.sh
    printf '%s' '${local.opensuse_signing_key_base64}' | base64 -d > /tmp/opensuse-project-signing-key.asc
    chmod 700 /tmp/verify-leapmicro-image.sh
    OPENSUSE_SIGNING_KEY_FILE=/tmp/opensuse-project-signing-key.asc /tmp/verify-leapmicro-image.sh
    [ -f "$VERIFIED_IMAGE_PATH" ] \
      || { echo "ERROR: signed checksum did not select the canonical appliance pathname" >&2; exit 1; }
  EOT

  write_x86_image = <<-EOT
    set -ex
    echo 'Leap Micro image loaded, writing to disk... '
    qemu-img convert -p -f qcow2 -O host_device '${local.opensuse_leapmicro_x86_image_path}' /dev/sda
    echo 'done. Rebooting...'
    sleep 1 && udevadm settle && reboot
  EOT

  write_arm_image = <<-EOT
    set -ex
    echo 'Leap Micro image loaded, writing to disk... '
    qemu-img convert -p -f qcow2 -O host_device '${local.opensuse_leapmicro_arm_image_path}' /dev/sda
    echo 'done. Rebooting...'
    sleep 1 && udevadm settle && reboot
  EOT

  install_packages = <<-EOT
    set -ex
    echo "First reboot successful, installing needed packages..."
    transactional-update --continue pkg install -y ${local.needed_packages}
    transactional-update --continue shell <<-'EOF'
    set -euo pipefail
    set -x

    setenforce 0 || true

    set +x
    printf '%s' '${local.rancher_rpm_installer_base64}' | base64 -d > /var/tmp/install-verified-rancher-rpm.sh
    printf '%s' '${local.rancher_rpm_verifier_base64}' | base64 -d > /var/tmp/verify-rancher-rpm.sh
    printf '%s' '${local.rancher_signing_key_base64}' | base64 -d > /var/tmp/rancher-ci-signing-key.asc
    chmod 700 /var/tmp/install-verified-rancher-rpm.sh /var/tmp/verify-rancher-rpm.sh
    set -x

    derive_rpm_version() {
      local tag="$1"
      echo "$tag" | sed -E 's/^v//; s/\.(stable|latest|testing)\..*$//'
    }

    install_k3s_selinux() {
      # k3s-selinux tag "v1.6.stable.1" => RPM "k3s-selinux-1.6-1.slemicro.noarch.rpm"
      K3S_TAG="${var.k3s_selinux_version}"
      K3S_RPM_VERSION="$(derive_rpm_version "$K3S_TAG")"
      if [ -z "$K3S_RPM_VERSION" ]; then
        echo "ERROR: failed to derive k3s-selinux RPM version from tag '$K3S_TAG'" >&2
        exit 1
      fi

      K3S_PACKAGE="${var.k3s_selinux_package_name}"
      if [ -z "$K3S_PACKAGE" ]; then
        K3S_PACKAGE="k3s-selinux-$K3S_RPM_VERSION-1.slemicro.noarch.rpm"
      fi

      K3S_URL="https://github.com/k3s-io/k3s-selinux/releases/download/$K3S_TAG/$K3S_PACKAGE"
      RPM_URL="$K3S_URL" \
      EXPECTED_RELEASE_TAG="$K3S_TAG" \
      EXPECTED_PACKAGE_FILE="$K3S_PACKAGE" \
      EXPECTED_PACKAGE_NAME=k3s-selinux \
      EXPECTED_RPM_SHA256=${local.k3s_selinux_expected_sha256_computed} \
      RANCHER_RPM_VERIFIER_FILE=/var/tmp/verify-rancher-rpm.sh \
      RANCHER_SIGNING_KEY_FILE=/var/tmp/rancher-ci-signing-key.asc \
      RANCHER_SIGNING_KEY_FINGERPRINT=${local.rancher_signing_key_fingerprint} \
        /var/tmp/install-verified-rancher-rpm.sh
      zypper addlock k3s-selinux
    }

    install_rke2_selinux() {
      # rke2-selinux tag "v0.22.stable.1" => RPM "rke2-selinux-0.22-1.slemicro.noarch.rpm"
      RKE2_TAG="${var.rke2_selinux_version}"
      RKE2_RPM_VERSION="$(derive_rpm_version "$RKE2_TAG")"
      if [ -z "$RKE2_RPM_VERSION" ]; then
        echo "ERROR: failed to derive rke2-selinux RPM version from tag '$RKE2_TAG'" >&2
        exit 1
      fi

      RKE2_PACKAGE="${var.rke2_selinux_package_name}"
      if [ -z "$RKE2_PACKAGE" ]; then
        RKE2_PACKAGE="rke2-selinux-$RKE2_RPM_VERSION-1.slemicro.noarch.rpm"
      fi

      RKE2_URL="https://github.com/rancher/rke2-selinux/releases/download/$RKE2_TAG/$RKE2_PACKAGE"
      RPM_URL="$RKE2_URL" \
      EXPECTED_RELEASE_TAG="$RKE2_TAG" \
      EXPECTED_PACKAGE_FILE="$RKE2_PACKAGE" \
      EXPECTED_PACKAGE_NAME=rke2-selinux \
      EXPECTED_RPM_SHA256=${local.rke2_selinux_expected_sha256_computed} \
      RANCHER_RPM_VERIFIER_FILE=/var/tmp/verify-rancher-rpm.sh \
      RANCHER_SIGNING_KEY_FILE=/var/tmp/rancher-ci-signing-key.asc \
      RANCHER_SIGNING_KEY_FINGERPRINT=${local.rancher_signing_key_fingerprint} \
        /var/tmp/install-verified-rancher-rpm.sh
      zypper addlock rke2-selinux
    }

    case "${var.selinux_package_to_install}" in
      k3s)
        install_k3s_selinux
        ;;
      rke2)
        install_rke2_selinux
        ;;
      *)
        echo "ERROR: invalid selinux_package_to_install='${var.selinux_package_to_install}', expected one of: k3s, rke2" >&2
        exit 1
        ;;
    esac

    rm -f /var/tmp/install-verified-rancher-rpm.sh /var/tmp/verify-rancher-rpm.sh /var/tmp/rancher-ci-signing-key.asc

    restorecon -Rv /etc/selinux/targeted/policy
    restorecon -Rv /var/lib
    setenforce 1 || true

    # Set a real password hash for root inside TU (so the hash persists in the
    # snapshot). The ! lock prefix will be stripped later in clean_up, AFTER
    # booting into this snapshot — because tukit's etc overlay finalization
    # can restore the ! prefix even after sed removes it inside the chroot.
    set +x
    _PW="$(openssl rand -base64 32)"
    _HASH="$(openssl passwd -6 -salt "$(openssl rand -hex 8)" "$_PW")"
    usermod -p "$_HASH" root
    unset _PW _HASH
    set -x

    # Bake a systemd oneshot that unlocks root on every boot, before sshd.
    # This is the hard fix — survives transactional-updates, reboots, and
    # cloud-init passwd -l root (which only fires per-instance anyway).
    cat > /etc/systemd/system/unlock-root-ssh.service <<'UNIT'
[Unit]
Description=Ensure root account is unlocked for SSH pubkey auth
Before=sshd.service ssh.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sed -i "s/^root:!/root:/" /etc/shadow'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl enable unlock-root-ssh.service

    ${local.sysctl_commands}
EOF
    sleep 1 && udevadm settle && reboot
  EOT

  clean_up = <<-EOT
    set -ex
    echo "Second reboot successful, cleaning-up..."

    verify_baked_selinux_package() {
      package_name="$1"
      package_file="$2"
      policy_name="$3"
      policy_file="$4"
      package_stem="$${package_file%.noarch.rpm}"
      version_release="$${package_stem#"$${package_name}"-}"
      expected_version="$${version_release%-*}"
      expected_release="$${version_release##*-}"
      expected_nevra="$${package_name}|0|$${expected_version}|$${expected_release}|noarch"
      actual_nevra="$(rpm -q --queryformat '%%{NAME}|%%{EPOCHNUM}|%%{VERSION}|%%{RELEASE}|%%{ARCH}' "$package_name")"

      [ "$actual_nevra" = "$expected_nevra" ] \
        || { echo "ERROR: baked SELinux package identity changed across the transactional reboot" >&2; exit 1; }
      rpm -V "$package_name" \
        || { echo "ERROR: baked SELinux package files changed across the transactional reboot" >&2; exit 1; }
      [ -s "$policy_file" ] \
        || { echo "ERROR: baked SELinux policy payload is missing after the transactional reboot" >&2; exit 1; }
      semodule -l | awk '{ print $1 }' | grep -qx "$policy_name" \
        || { echo "ERROR: baked SELinux policy is not loaded after the transactional reboot" >&2; exit 1; }
      [ "$(getenforce)" = "Enforcing" ] \
        || { echo "ERROR: SELinux is not enforcing after the transactional reboot" >&2; exit 1; }
    }

    case "${var.selinux_package_to_install}" in
      k3s)
        K3S_TAG="${var.k3s_selinux_version}"
        K3S_RPM_VERSION="$(echo "$K3S_TAG" | sed -E 's/^v//; s/\.(stable|latest|testing)\..*$//')"
        K3S_PACKAGE="${var.k3s_selinux_package_name}"
        if [ -z "$K3S_PACKAGE" ]; then
          K3S_PACKAGE="k3s-selinux-$K3S_RPM_VERSION-1.slemicro.noarch.rpm"
        fi
        verify_baked_selinux_package k3s-selinux "$K3S_PACKAGE" k3s /usr/share/selinux/packages/k3s.pp
        ;;
      rke2)
        RKE2_TAG="${var.rke2_selinux_version}"
        RKE2_RPM_VERSION="$(echo "$RKE2_TAG" | sed -E 's/^v//; s/\.(stable|latest|testing)\..*$//')"
        RKE2_PACKAGE="${var.rke2_selinux_package_name}"
        if [ -z "$RKE2_PACKAGE" ]; then
          RKE2_PACKAGE="rke2-selinux-$RKE2_RPM_VERSION-1.slemicro.noarch.rpm"
        fi
        verify_baked_selinux_package rke2-selinux "$RKE2_PACKAGE" rke2 /usr/share/selinux/packages/rke2.pp
        ;;
      *)
        echo "ERROR: invalid selinux_package_to_install='${var.selinux_package_to_install}' during verification" >&2
        exit 1
        ;;
    esac
    # Unlock root for SSH pubkey auth. This MUST run on the live booted system
    # (not inside transactional-update shell) because tukit's etc overlay
    # finalization restores the ! lock prefix. On SUSE, usermod -p preserves
    # the ! prefix (!$6$...), so we strip it with sed on the live /etc/shadow.
    # The hash was set inside TU; here we just remove the lock prefix.
    sed -i 's/^root:!/root:/' /etc/shadow
    # Verify: shadow field must start with $6$ (real hash, no ! prefix)
    getent shadow root | cut -d: -f2 | grep -q '^\$6\$' \
      || { echo "FATAL: root password state is invalid after unlock" >&2; exit 1; }

    echo "Committing final image cleanup into the pending transactional snapshot..."
    transactional-update --continue shell <<-'EOF'
    set -eux

    rm -f /etc/ssh/ssh_host_*
    if find /etc/ssh -maxdepth 1 -name 'ssh_host_*' -print -quit | grep -q .; then
      echo "ERROR: SSH host keys remain in the committed image snapshot" >&2
      exit 1
    fi

    install -d -m 0755 /etc/NetworkManager
    [ ! -L /etc/NetworkManager/NetworkManager.conf ] \
      || { echo "ERROR: NetworkManager configuration path must not be a symbolic link" >&2; exit 1; }
    if [ ! -f /etc/NetworkManager/NetworkManager.conf ]; then
      install -m 0644 /dev/null /etc/NetworkManager/NetworkManager.conf
    fi

    timezone='${var.timezone}'
    zoneinfo="/usr/share/zoneinfo/$timezone"
    [ -e "$zoneinfo" ] \
      || { echo "ERROR: configured timezone is not present in the Leap Micro zoneinfo database" >&2; exit 1; }
    resolved_zone="$(readlink -f -- "$zoneinfo")"
    case "$resolved_zone" in
      /usr/share/zoneinfo/*) ;;
      *) echo "ERROR: configured timezone resolves outside the zoneinfo database" >&2; exit 1 ;;
    esac
    ln -snf "$zoneinfo" /etc/localtime
    printf '%s\n' "$timezone" > /etc/timezone
    [ "$(readlink -f -- /etc/localtime)" = "$resolved_zone" ]
    [ "$(cat /etc/timezone)" = "$timezone" ]
EOF

    # /root is a persistent btrfs subvolume, outside the transactional root.
    # Remove Packer/Hetzner bootstrap keys on the live filesystem so they are
    # not inherited by every server created from the image snapshot.
    rm -f /root/.ssh/authorized_keys /root/.ssh/authorized_keys.kube-hetzner
    if [ -e /root/.ssh/authorized_keys ] || [ -e /root/.ssh/authorized_keys.kube-hetzner ]; then
      echo "ERROR: SSH authorized keys remain in the persistent root subvolume" >&2
      exit 1
    fi

    echo "Running fstrim to reduce snapshot size..."
    fstrim -av || true
    sleep 1 && udevadm settle
  EOT
}

# Source for the Leap Micro x86 snapshot
source "hcloud" "leapmicro-x86-snapshot" {
  image       = "ubuntu-24.04"
  rescue      = "linux64"
  location    = var.x86_location
  server_type = var.x86_server_type # disk size of >= 40GiB is needed to install the Leap Micro image
  snapshot_labels = {
    leapmicro-snapshot        = "yes"
    creator                   = "kube-hetzner"
    "kube-hetzner/os"         = "leapmicro"
    "kube-hetzner/arch"       = "x86"
    "kube-hetzner/built-at"   = local.snapshot_build_timestamp
    "kube-hetzner/build-id"   = local.snapshot_build_id
    "kube-hetzner/k8s-distro" = var.selinux_package_to_install
  }
  snapshot_name = "OpenSUSE Leap Micro x86 ${upper(var.selinux_package_to_install)} ${local.snapshot_build_timestamp}-${local.snapshot_build_id} by Kube-Hetzner"
  ssh_username  = "root"
  token         = var.hcloud_token
}

# Source for the Leap Micro ARM snapshot
source "hcloud" "leapmicro-arm-snapshot" {
  image       = "ubuntu-24.04"
  rescue      = "linux64"
  location    = var.arm_location
  server_type = var.arm_server_type # disk size of >= 40GiB is needed to install the Leap Micro image
  snapshot_labels = {
    leapmicro-snapshot        = "yes"
    creator                   = "kube-hetzner"
    "kube-hetzner/os"         = "leapmicro"
    "kube-hetzner/arch"       = "arm"
    "kube-hetzner/built-at"   = local.snapshot_build_timestamp
    "kube-hetzner/build-id"   = local.snapshot_build_id
    "kube-hetzner/k8s-distro" = var.selinux_package_to_install
  }
  snapshot_name = "OpenSUSE Leap Micro ARM ${upper(var.selinux_package_to_install)} ${local.snapshot_build_timestamp}-${local.snapshot_build_id} by Kube-Hetzner"
  ssh_username  = "root"
  token         = var.hcloud_token
}

# Build the Leap Micro x86 snapshot
build {
  sources = ["source.hcloud.leapmicro-x86-snapshot"]

  provisioner "shell" {
    environment_vars = [
      "IMAGE_URL=${local.opensuse_leapmicro_x86_mirror_link_computed}",
      "CHECKSUM_URL=${local.opensuse_leapmicro_x86_checksum_link_computed}",
      "SIGNATURE_URL=${local.opensuse_leapmicro_x86_signature_link_computed}",
      "EXPECTED_IMAGE_ARCH=x86_64",
      "EXPECTED_LEAP_MICRO_VERSION=${var.leap_micro_version}",
      "EXPECTED_IMAGE_SHA256=${local.opensuse_leapmicro_x86_expected_sha256_computed}",
      "CUSTOM_IMAGE=${var.opensuse_leapmicro_x86_mirror_link != "" ? 1 : 0}",
      "SIDECAR_URLS_EXPLICIT=${var.opensuse_leapmicro_x86_checksum_link != "" && var.opensuse_leapmicro_x86_signature_link != "" ? 1 : 0}",
      "MIRROR_AUTHORIZATION_HEADER=${var.opensuse_leapmicro_x86_mirror_authorization_header}",
      "OPENSUSE_SIGNING_KEY_FINGERPRINT=${local.opensuse_signing_key_fingerprint}",
      "VERIFIED_IMAGE_PATH=${local.opensuse_leapmicro_x86_image_path}",
    ]
    use_env_var_file = true
    inline           = [local.download_and_verify_image]
  }

  provisioner "shell" {
    inline            = [local.write_x86_image]
    expect_disconnect = true
  }

  provisioner "shell" {
    pause_before      = "5s"
    inline            = [local.install_packages]
    expect_disconnect = true
  }

  provisioner "shell" {
    pause_before = "5s"
    inline       = [local.clean_up]
  }
}

# Build the Leap Micro ARM snapshot
build {
  sources = ["source.hcloud.leapmicro-arm-snapshot"]

  provisioner "shell" {
    environment_vars = [
      "IMAGE_URL=${local.opensuse_leapmicro_arm_mirror_link_computed}",
      "CHECKSUM_URL=${local.opensuse_leapmicro_arm_checksum_link_computed}",
      "SIGNATURE_URL=${local.opensuse_leapmicro_arm_signature_link_computed}",
      "EXPECTED_IMAGE_ARCH=aarch64",
      "EXPECTED_LEAP_MICRO_VERSION=${var.leap_micro_version}",
      "EXPECTED_IMAGE_SHA256=${local.opensuse_leapmicro_arm_expected_sha256_computed}",
      "CUSTOM_IMAGE=${var.opensuse_leapmicro_arm_mirror_link != "" ? 1 : 0}",
      "SIDECAR_URLS_EXPLICIT=${var.opensuse_leapmicro_arm_checksum_link != "" && var.opensuse_leapmicro_arm_signature_link != "" ? 1 : 0}",
      "MIRROR_AUTHORIZATION_HEADER=${var.opensuse_leapmicro_arm_mirror_authorization_header}",
      "OPENSUSE_SIGNING_KEY_FINGERPRINT=${local.opensuse_signing_key_fingerprint}",
      "VERIFIED_IMAGE_PATH=${local.opensuse_leapmicro_arm_image_path}",
    ]
    use_env_var_file = true
    inline           = [local.download_and_verify_image]
  }

  provisioner "shell" {
    inline            = [local.write_arm_image]
    expect_disconnect = true
  }

  provisioner "shell" {
    pause_before      = "5s"
    inline            = [local.install_packages]
    expect_disconnect = true
  }

  provisioner "shell" {
    pause_before = "5s"
    inline       = [local.clean_up]
  }
}
