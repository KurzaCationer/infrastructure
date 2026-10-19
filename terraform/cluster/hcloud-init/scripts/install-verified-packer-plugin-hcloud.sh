#!/usr/bin/env bash

set -euo pipefail

readonly plugin_version=1.7.2
readonly plugin_api_version=x5.0
readonly plugin_source=github.com/hetznercloud/hcloud
readonly required_packer_version=1.16.0
readonly expected_plugin_description='{"version":"1.7.2","sdk_version":"0.6.6","api_version":"x5.0","builders":["-packer-default-plugin-name-"],"post_processors":[],"provisioners":[],"datasources":[],"protocol_version":"v2"}'
hcloud_plugin_state_directory=""

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage: install-verified-packer-plugin-hcloud.sh [REVIEWED_PLUGIN_ARCHIVE]

Downloads, verifies, and installs kube-hetzner's reviewed hcloud Packer plugin.
An optional local archive supports offline installation but must match the same
platform-specific repository-owned SHA-256 pin. PACKER_PLUGIN_PATH is honored
when set; otherwise Packer installs into its normal per-user plugin directory.
USAGE
  exit 2
}

cleanup_hcloud_plugin_installer() {
  [[ -z "$hcloud_plugin_state_directory" ]] || rm -rf "$hcloud_plugin_state_directory"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print tolower($1) }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print tolower($1) }'
  else
    fail "sha256sum or shasum is required"
  fi
}

resolve_platform() {
  local kernel="$1"
  local machine="$2"

  case "$kernel:$machine" in
    Darwin:x86_64) printf '%s\n' darwin_amd64 ;;
    Darwin:arm64) printf '%s\n' darwin_arm64 ;;
    Linux:x86_64 | Linux:amd64) printf '%s\n' linux_amd64 ;;
    Linux:aarch64 | Linux:arm64) printf '%s\n' linux_arm64 ;;
    *) fail "unsupported hcloud Packer plugin platform: $kernel $machine" ;;
  esac
}

expected_archive_sha256() {
  case "$1" in
    darwin_amd64) printf '%s\n' 2337ba810bbfdd0c011826f1cda647411945521b5e06abcec42550b5ba2d4050 ;;
    darwin_arm64) printf '%s\n' 5fc34e07bd7a97cd2c5c367fbbab9db9beb03fd47706c70a02bf8d3b02f6d05b ;;
    linux_amd64) printf '%s\n' a2e818ff4f67dca19b1ef4b6f636e6bcb1f5d8cbab4f320a4e90d997eafc37d6 ;;
    linux_arm64) printf '%s\n' 4cd397e95e5003cffa59bb45e37850ad692c456469d677f0f9cc3a3834e55385 ;;
    *) fail "missing hcloud Packer plugin digest for platform $1" ;;
  esac
}

verify_sha256() {
  local archive="$1"
  local expected="$2"
  local actual
  actual="$(sha256_file "$archive")"
  [[ "$actual" == "$expected" ]] \
    || fail "hcloud Packer plugin archive digest mismatch: expected $expected, got $actual"
}

verify_archive_shape() {
  local archive="$1"
  local expected_binary_name="$2"
  local archive_members
  archive_members="$(unzip -Z1 "$archive")" \
    || fail "unable to inspect hcloud Packer plugin archive"
  [[ "$archive_members" == "$expected_binary_name" ]] \
    || fail "hcloud Packer plugin archive must contain exactly $expected_binary_name"
}

verify_plugin_metadata() {
  local binary="$1"
  local description
  [[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] \
    || fail "extracted hcloud Packer plugin is not a regular executable"
  description="$("$binary" describe 2>/dev/null)" \
    || fail "hcloud Packer plugin describe command failed"
  [[ "$description" == "$expected_plugin_description" ]] \
    || fail "hcloud Packer plugin metadata does not match reviewed version 1.7.2"
}

verify_packer_version() {
  local packer_command="$1"
  local version_line
  command -v "$packer_command" >/dev/null 2>&1 || fail "Packer is required"
  version_line="$("$packer_command" version 2>/dev/null | sed -n '1p')" \
    || fail "unable to determine the installed Packer version"
  [[ "$version_line" == "Packer v$required_packer_version" ]] \
    || fail "Packer $required_packer_version is required; found '${version_line:-unknown}'"
}

install_plugin() {
  local binary="$1"
  local expected_binary_name="$2"
  local packer_command="$3"
  local installed_plugins

  "$packer_command" plugins install -force --path "$binary" "$plugin_source"
  installed_plugins="$("$packer_command" plugins installed)"
  grep -Fq "$expected_binary_name" <<< "$installed_plugins" \
    || fail "Packer did not report the verified hcloud plugin after installation"
}

main() {
  [[ $# -le 1 ]] || usage

  local packer_command="${PACKER_BIN:-packer}"
  local platform
  local digest
  local archive_name
  local binary_name
  local plugin_url
  local archive
  local extracted_directory
  local source_archive="${1:-}"

  for tool in awk basename chmod cp dirname grep mkdir mktemp sed uname unzip; do
    command -v "$tool" >/dev/null 2>&1 || fail "required plugin installation tool '$tool' is unavailable"
  done
  if [[ -z "$source_archive" ]]; then
    command -v curl >/dev/null 2>&1 || fail "required plugin installation tool 'curl' is unavailable"
  fi
  verify_packer_version "$packer_command"

  platform="$(resolve_platform "$(uname -s)" "$(uname -m)")"
  digest="$(expected_archive_sha256 "$platform")"
  archive_name="packer-plugin-hcloud_v${plugin_version}_${plugin_api_version}_${platform}.zip"
  binary_name="${archive_name%.zip}"
  plugin_url="https://github.com/hetznercloud/packer-plugin-hcloud/releases/download/v${plugin_version}/${archive_name}"
  hcloud_plugin_state_directory="$(mktemp -d "${TMPDIR:-/tmp}/kh-packer-plugin-hcloud.XXXXXX")"
  archive="$hcloud_plugin_state_directory/$archive_name"
  extracted_directory="$hcloud_plugin_state_directory/plugin"

  trap cleanup_hcloud_plugin_installer EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [[ -n "$source_archive" ]]; then
    [[ -f "$source_archive" && ! -L "$source_archive" ]] \
      || fail "reviewed plugin archive must be a regular file, not a symbolic link"
    source_archive="$(cd "$(dirname "$source_archive")" && pwd -P)/$(basename "$source_archive")"
    cp "$source_archive" "$archive"
  else
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
      --tlsv1.2 --retry 3 --retry-all-errors --connect-timeout 20 --max-time 300 \
      --max-filesize 268435456 \
      --output "$archive" "$plugin_url"
  fi

  verify_sha256 "$archive" "$digest"
  verify_archive_shape "$archive" "$binary_name"
  mkdir -p "$extracted_directory"
  unzip -q "$archive" -d "$extracted_directory"
  chmod +x "$extracted_directory/$binary_name"
  verify_plugin_metadata "$extracted_directory/$binary_name"
  install_plugin "$extracted_directory/$binary_name" "$binary_name" "$packer_command"

  if [[ -n "${PACKER_PLUGIN_PATH:-}" ]]; then
    printf 'Verified and installed hcloud Packer plugin %s into PACKER_PLUGIN_PATH=%s.\n' \
      "$plugin_version" "$PACKER_PLUGIN_PATH"
  else
    printf "Verified and installed hcloud Packer plugin %s into Packer's normal plugin directory.\n" \
      "$plugin_version"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
