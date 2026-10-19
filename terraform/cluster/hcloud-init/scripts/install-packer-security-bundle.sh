#!/usr/bin/env bash

set -euo pipefail

readonly manifest_name="security-bundle.sha256"
readonly generation_prefix=".kube-hetzner-packer-security."
readonly expected_paths="
hcloud-leapmicro-snapshots.pkr.hcl
hcloud-microos-snapshots.pkr.hcl
keys/opensuse-project-signing-key.asc
keys/rancher-ci-signing-key.asc
scripts/install-packer-security-bundle.sh
scripts/install-verified-packer-plugin-hcloud.sh
scripts/install-verified-rancher-rpm.sh
scripts/verify-leapmicro-image.sh
scripts/verify-microos-image.sh
scripts/verify-rancher-rpm.sh
"

die() {
  echo "Packer security bundle: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage: install-packer-security-bundle.sh SOURCE_PACKER_DIR DESTINATION_PACKER_DIR EXPECTED_MANIFEST_SHA256

Publishes the manifest-bound Packer templates, signing keys, and verification
scripts through one atomic directory link. Existing complete bundles must match
byte-for-byte; partial, legacy, or modified bundles fail closed. kube.tf is
intentionally outside this bundle.
USAGE
  exit 2
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

is_expected_path() {
  case "$1" in
    hcloud-leapmicro-snapshots.pkr.hcl | \
    hcloud-microos-snapshots.pkr.hcl | \
    keys/opensuse-project-signing-key.asc | \
    keys/rancher-ci-signing-key.asc | \
    scripts/install-packer-security-bundle.sh | \
    scripts/install-verified-packer-plugin-hcloud.sh | \
    scripts/install-verified-rancher-rpm.sh | \
    scripts/verify-leapmicro-image.sh | \
    scripts/verify-microos-image.sh | \
    scripts/verify-rancher-rpm.sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_bundle_directory() {
  local bundle_root="$1"
  local marker="$bundle_root/$manifest_name"
  local digest
  local relative_path
  local bundle_file

  [[ -f "$marker" && ! -L "$marker" ]] \
    || die "existing bundle is partial: missing regular $manifest_name"
  cmp -s "$manifest" "$marker" \
    || die "existing bundle manifest differs from the requested release"

  while IFS='|' read -r digest relative_path; do
    bundle_file="$bundle_root/$relative_path"
    [[ -f "$bundle_file" && ! -L "$bundle_file" ]] \
      || die "bundle path is missing or is a symbolic link: $relative_path"
    [[ "$(sha256_file "$bundle_file")" == "$digest" ]] \
      || die "bundle file was modified: $relative_path"
  done < "$records_file"
}

[[ $# -eq 3 ]] || usage

source_root="$1"
destination="$2"
expected_manifest_sha256="$3"

[[ -d "$source_root" && ! -L "$source_root" ]] \
  || die "source directory is missing or is a symbolic link: $source_root"
source_root="$(cd "$source_root" && pwd -P)"
source_manifest="$source_root/$manifest_name"
[[ -f "$source_manifest" && ! -L "$source_manifest" ]] \
  || die "missing regular manifest: $source_manifest"

case "$expected_manifest_sha256" in
  *[!0-9a-f]* | '') die "expected manifest SHA-256 must be 64 lowercase hexadecimal characters" ;;
esac
[[ ${#expected_manifest_sha256} -eq 64 ]] \
  || die "expected manifest SHA-256 must be 64 lowercase hexadecimal characters"

state_directory="$(mktemp -d "${TMPDIR:-/tmp}/kh-packer-bundle.XXXXXX")"
manifest="$state_directory/$manifest_name"
records_file="$state_directory/records"
stage_directory=""
lock_directory=""
cleanup() {
  if [[ -n "$stage_directory" ]]; then
    if [[ -L "$destination" ]] \
      && [[ "$(readlink "$destination")" == "$(basename "$stage_directory")" ]]; then
      rm -f "$destination"
    fi
    rm -rf "$stage_directory"
  fi
  [[ -z "$lock_directory" ]] || rm -rf "$lock_directory"
  rm -rf "$state_directory"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# All parsing and publication use one private, digest-bound manifest snapshot.
# The caller's source directory can otherwise change between verification and
# use, producing a time-of-check/time-of-use trust gap.
cp -p "$source_manifest" "$manifest"
actual_manifest_sha256="$(sha256_file "$manifest")"
[[ "$actual_manifest_sha256" == "$expected_manifest_sha256" ]] \
  || die "manifest digest mismatch: expected $expected_manifest_sha256, got $actual_manifest_sha256"
: > "$records_file"

entry_count=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  case "$line" in
    '' | \#*) continue ;;
  esac

  digest="${line%%[[:space:]]*}"
  relative_path="${line#"$digest"}"
  relative_path="${relative_path#"${relative_path%%[![:space:]]*}"}"

  case "$digest" in
    *[!0-9a-f]* | '') die "invalid digest in manifest entry: $line" ;;
  esac
  [[ ${#digest} -eq 64 ]] || die "invalid digest length in manifest entry: $line"
  [[ -n "$relative_path" ]] || die "missing path in manifest entry: $line"
  case "$relative_path" in
    *[[:space:]]* | /* | ../* | */../* | */.. | . | ..)
      die "unsafe or unsupported manifest path: $relative_path"
      ;;
  esac
  is_expected_path "$relative_path" || die "unexpected manifest path: $relative_path"
  ! cut -d '|' -f 2 "$records_file" | grep -Fxq "$relative_path" \
    || die "duplicate manifest path: $relative_path"

  source_file="$source_root/$relative_path"
  [[ -f "$source_file" && ! -L "$source_file" ]] \
    || die "bundle source is missing or is a symbolic link: $relative_path"
  actual_digest="$(sha256_file "$source_file")"
  [[ "$actual_digest" == "$digest" ]] \
    || die "bundle source digest mismatch for $relative_path"

  printf '%s|%s\n' "$digest" "$relative_path" >> "$records_file"
  entry_count=$((entry_count + 1))
done < "$manifest"

[[ $entry_count -eq 10 ]] || die "manifest must contain exactly ten bundle files"
while IFS= read -r relative_path; do
  [[ -z "$relative_path" ]] && continue
  cut -d '|' -f 2 "$records_file" | grep -Fxq "$relative_path" \
    || die "manifest is missing required path: $relative_path"
done <<< "$expected_paths"

destination_parent="$(dirname "$destination")"
destination_name="$(basename "$destination")"
[[ "$destination_name" != . && "$destination_name" != .. ]] \
  || die "destination must name a bundle directory"
[[ ! -L "$destination_parent" ]] \
  || die "destination parent must not be a symbolic link: $destination_parent"
mkdir -p "$destination_parent"
destination_parent="$(cd "$destination_parent" && pwd -P)"
destination="$destination_parent/$destination_name"

lock_directory="$destination_parent/.${destination_name}.kube-hetzner-install.lock"
lock_acquired=false
for ((attempt = 0; attempt < 300; attempt++)); do
  if mkdir "$lock_directory" 2>/dev/null; then
    lock_acquired=true
    break
  fi
  sleep 0.1
done
[[ "$lock_acquired" == true ]] \
  || die "bundle installation remained locked; inspect stale lock $lock_directory"
printf '%s\n' "$$" > "$lock_directory/pid"

if [[ -e "$destination" || -L "$destination" ]]; then
  [[ -L "$destination" ]] \
    || die "existing bundle path is not an atomically published link: $destination"
  link_target="$(readlink "$destination")"
  case "$link_target" in
    "$generation_prefix"* ) ;;
    *) die "existing bundle link has an unexpected target: $link_target" ;;
  esac
  case "$link_target" in
    */* | . | ..) die "existing bundle link escapes its project directory" ;;
  esac
  [[ -d "$destination_parent/$link_target" && ! -L "$destination_parent/$link_target" ]] \
    || die "existing bundle link is dangling or does not target a regular directory"
  validate_bundle_directory "$destination_parent/$link_target"
  echo "Packer security bundle already matches manifest $expected_manifest_sha256."
  exit 0
fi

# Old create.sh versions placed managed files directly in the project root.
# Mixing that layout with the atomic bundle would make Packer trust ambiguous.
while IFS= read -r relative_path; do
  [[ -z "$relative_path" ]] && continue
  if [[ -e "$destination_parent/$relative_path" || -L "$destination_parent/$relative_path" ]]; then
    die "legacy or partial bundle path exists outside $destination_name: $relative_path"
  fi
done <<< "$expected_paths"
for orphan in "$destination_parent/$generation_prefix"*; do
  [[ -e "$orphan" || -L "$orphan" ]] || continue
  die "unpublished bundle generation exists; inspect and remove it before retrying: $orphan"
done

stage_directory="$(mktemp -d "$destination_parent/$generation_prefix${expected_manifest_sha256}.XXXXXX")"
while IFS='|' read -r digest relative_path; do
  mkdir -p "$stage_directory/$(dirname "$relative_path")"
  cp -p "$source_root/$relative_path" "$stage_directory/$relative_path"
  [[ "$(sha256_file "$stage_directory/$relative_path")" == "$digest" ]] \
    || die "staged bundle digest mismatch for $relative_path"
done < "$records_file"
cp -p "$manifest" "$stage_directory/$manifest_name"
validate_bundle_directory "$stage_directory"

# The generation is invisible until this single no-clobber symlink publish.
ln -s "$(basename "$stage_directory")" "$destination" 2>/dev/null \
  || die "bundle destination appeared during installation: $destination"
stage_directory=""
echo "Installed Packer security bundle at $destination with manifest $expected_manifest_sha256."
