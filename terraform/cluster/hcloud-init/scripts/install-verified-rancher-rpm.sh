#!/bin/bash

set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

for variable in EXPECTED_PACKAGE_FILE EXPECTED_PACKAGE_NAME RANCHER_RPM_VERIFIER_FILE RANCHER_SIGNING_KEY_FILE; do
  [[ -n "${!variable:-}" ]] || fail "required environment variable $variable is empty"
done

for tool in mktemp rpm zypper; do
  command -v "$tool" >/dev/null 2>&1 || fail "required RPM installation tool '$tool' is unavailable"
done
[[ -x "$RANCHER_RPM_VERIFIER_FILE" ]] || fail "Rancher RPM verifier is missing or not executable"

work_dir="$(mktemp -d)"
rpm_file="$work_dir/$EXPECTED_PACKAGE_FILE"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

OUTPUT_RPM_FILE="$rpm_file" "$RANCHER_RPM_VERIFIER_FILE"

package_query_format=$'%{NAME}\t%{EPOCHNUM}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\n'
expected_nevra="$(rpm -qp --queryformat "$package_query_format" "$rpm_file")"
rpm --import "$RANCHER_SIGNING_KEY_FILE"
zypper --non-interactive install -y "$rpm_file"
actual_nevra="$(rpm -q --queryformat "$package_query_format" "$EXPECTED_PACKAGE_NAME")"
[[ "$actual_nevra" == "$expected_nevra" ]] || fail "installed SELinux RPM identity does not match the verified package"
