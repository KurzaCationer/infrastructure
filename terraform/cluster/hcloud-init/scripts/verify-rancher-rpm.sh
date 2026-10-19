#!/bin/bash

set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

for variable in RPM_URL EXPECTED_RELEASE_TAG EXPECTED_PACKAGE_FILE EXPECTED_PACKAGE_NAME EXPECTED_RPM_SHA256 OUTPUT_RPM_FILE RANCHER_SIGNING_KEY_FILE RANCHER_SIGNING_KEY_FINGERPRINT; do
  [[ -n "${!variable:-}" ]] || fail "required environment variable $variable is empty"
done

for tool in awk date dirname gpg mkdir mktemp rpm rpmkeys sha256sum tr wget; do
  command -v "$tool" >/dev/null 2>&1 || fail "required RPM verification tool '$tool' is unavailable"
done

[[ "$EXPECTED_PACKAGE_FILE" =~ ^${EXPECTED_PACKAGE_NAME}-[A-Za-z0-9._+~]+-[A-Za-z0-9._+~]+\.noarch\.rpm$ ]] \
  || fail "SELinux RPM filename is unsafe or inconsistent with package name"
[[ "$EXPECTED_RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.(stable|latest|testing)\.[0-9]+$ ]] \
  || fail "SELinux RPM release tag is malformed"
[[ "$EXPECTED_RPM_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]] \
  || fail "SELinux RPM SHA-256 must be exactly 64 hexadecimal characters"
EXPECTED_RPM_SHA256="$(printf '%s' "$EXPECTED_RPM_SHA256" | tr '[:upper:]' '[:lower:]')"

case "$EXPECTED_PACKAGE_NAME" in
  k3s-selinux) expected_repository=k3s-io/k3s-selinux ;;
  rke2-selinux) expected_repository=rancher/rke2-selinux ;;
  *) fail "unsupported SELinux package name" ;;
esac
expected_url="https://github.com/$expected_repository/releases/download/$EXPECTED_RELEASE_TAG/$EXPECTED_PACKAGE_FILE"
[[ "$RPM_URL" == "$expected_url" ]] || fail "SELinux RPM URL does not match the exact expected repository, tag, and filename"
[[ -r "$RANCHER_SIGNING_KEY_FILE" ]] || fail "vendored Rancher signing key is unreadable"
[[ ! -L "$OUTPUT_RPM_FILE" ]] || fail "SELinux RPM output path must not be a symbolic link"
mkdir -p "$(dirname "$OUTPUT_RPM_FILE")"

key_record="$(gpg --batch --show-keys --with-colons "$RANCHER_SIGNING_KEY_FILE" 2>/dev/null | awk -F: '
  $1 == "pub" {
    validity = $2
    created = $6
    expiry = ($7 == "" ? 0 : $7)
    capabilities = $12
    primary = 1
    next
  }
  primary && $1 == "fpr" {
    print $10 "|" validity "|" created "|" expiry "|" capabilities
    primary = 0
  }
')"
[[ "$(awk 'NF { count++ } END { print count + 0 }' <<< "$key_record")" == 1 ]] \
  || fail "pinned Rancher key must contain exactly one primary key"
IFS='|' read -r key_fingerprint key_validity key_created key_expiry key_capabilities <<< "$key_record"
[[ "$key_fingerprint" == "$RANCHER_SIGNING_KEY_FINGERPRINT" ]] \
  || fail "Rancher signing key does not match the pinned primary fingerprint"
case "$key_validity" in
  - | u | f | m) ;;
  *) fail "pinned Rancher signing key is revoked, expired, disabled, or invalid" ;;
esac
[[ "$key_created" =~ ^[0-9]+$ && "$key_expiry" =~ ^[0-9]+$ ]] \
  || fail "pinned Rancher key lifecycle timestamps are malformed"
[[ "$key_capabilities" == *s* || "$key_capabilities" == *S* ]] \
  || fail "pinned Rancher primary key is not signing-capable"
now="$(date +%s)"
((key_created <= now + 300)) || fail "pinned Rancher key has a future creation time"
if [[ "$key_expiry" != 0 && "$key_expiry" -le "$now" ]]; then
  fail "pinned Rancher signing key has expired; review and update the vendored trust anchor"
fi

verify_db="$(mktemp -d)"
verified=0
cleanup() {
  rm -rf "$verify_db"
  if ((verified == 0)); then
    rm -f "$OUTPUT_RPM_FILE"
  fi
}
trap cleanup EXIT HUP INT TERM

if ! wget -q --timeout=5 --waitretry=5 --tries=5 --retry-connrefused --inet4-only -O "$OUTPUT_RPM_FILE" "$RPM_URL"; then
  fail "failed to download the requested SELinux policy RPM"
fi
actual_rpm_sha256="$(sha256sum "$OUTPUT_RPM_FILE" | awk '{ print tolower($1) }')"
[[ "$actual_rpm_sha256" == "$EXPECTED_RPM_SHA256" ]] \
  || fail "SELinux policy RPM does not match the reviewed SHA-256 digest pin"

rpm --dbpath "$verify_db" --initdb
rpm --dbpath "$verify_db" --import "$RANCHER_SIGNING_KEY_FILE"
rpmkeys --dbpath "$verify_db" --define '_pkgverify_level signature' --checksig "$OUTPUT_RPM_FILE" >/dev/null \
  || fail "SELinux policy RPM signature verification failed against the isolated pinned-key database"

package_stem="${EXPECTED_PACKAGE_FILE%.noarch.rpm}"
version_release="${package_stem#"${EXPECTED_PACKAGE_NAME}"-}"
expected_version="${version_release%-*}"
expected_release="${version_release##*-}"
package_metadata="$(rpm --dbpath "$verify_db" -qp --queryformat $'%{NAME}|%{VERSION}|%{RELEASE}|%{ARCH}\n' "$OUTPUT_RPM_FILE")"
IFS='|' read -r package_name package_version package_release package_arch <<< "$package_metadata"
[[ "$package_name" == "$EXPECTED_PACKAGE_NAME" ]] || fail "SELinux RPM package name mismatch"
[[ "$package_version" == "$expected_version" ]] || fail "SELinux RPM package version mismatch"
[[ "$package_release" == "$expected_release" ]] || fail "SELinux RPM package release mismatch"
[[ "$package_arch" == "noarch" ]] || fail "SELinux RPM architecture mismatch"

verified=1
printf 'Verified %s release %s (%s).\n' "$EXPECTED_PACKAGE_NAME" "$EXPECTED_RELEASE_TAG" "$actual_rpm_sha256"
