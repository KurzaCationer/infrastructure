#!/bin/sh

set -eu

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

require_env() {
  eval "value=\${$1-}"
  [ -n "$value" ] || fail "required environment variable $1 is empty"
}

for variable in \
  IMAGE_URL \
  CHECKSUM_URL \
  SIGNATURE_URL \
  EXPECTED_IMAGE_ARCH \
  CUSTOM_IMAGE \
  SIDECAR_URLS_EXPLICIT \
  VERIFIED_IMAGE_PATH \
  OPENSUSE_SIGNING_KEY_FILE \
  OPENSUSE_SIGNING_KEY_FINGERPRINT; do
  require_env "$variable"
done

verified_path_without_controls="$(printf '%s' "$VERIFIED_IMAGE_PATH" | LC_ALL=C tr -d '\000-\037\177')"
[ "$VERIFIED_IMAGE_PATH" = "$verified_path_without_controls" ] \
  || fail "VERIFIED_IMAGE_PATH must not contain control characters"
case "$VERIFIED_IMAGE_PATH" in
  /*) ;;
  *) fail "VERIFIED_IMAGE_PATH must be an absolute path" ;;
esac
[ -d "$(dirname "$VERIFIED_IMAGE_PATH")" ] \
  || fail "VERIFIED_IMAGE_PATH parent directory does not exist"
[ ! -e "$VERIFIED_IMAGE_PATH" ] \
  || fail "VERIFIED_IMAGE_PATH already exists"

for tool in awk date dirname gpg mktemp sha256sum tr wc wget; do
  command -v "$tool" >/dev/null 2>&1 || fail "required verification tool '$tool' is unavailable"
done

case "$EXPECTED_IMAGE_ARCH" in
  x86_64 | aarch64) ;;
  *) fail "unsupported appliance architecture '$EXPECTED_IMAGE_ARCH'" ;;
esac

case "$CUSTOM_IMAGE" in
  0 | 1) ;;
  *) fail "CUSTOM_IMAGE must be 0 or 1" ;;
esac

case "$SIDECAR_URLS_EXPLICIT" in
  0 | 1) ;;
  *) fail "SIDECAR_URLS_EXPLICIT must be 0 or 1" ;;
esac

if [ "$CUSTOM_IMAGE" = 1 ] && [ "$SIDECAR_URLS_EXPLICIT" != 1 ]; then
  fail "custom image mode requires explicit checksum and signature URLs"
fi

for url_name in IMAGE_URL CHECKSUM_URL SIGNATURE_URL; do
  eval "url=\${$url_name}"
  url_without_controls="$(printf '%s' "$url" | LC_ALL=C tr -d '\000-\037\177')"
  [ "$url" = "$url_without_controls" ] || fail "$url_name must not contain control characters"
  case "$url" in
    *'#'*) fail "$url_name must not contain a URL fragment" ;;
    *://*@*) fail "$url_name must not contain credentials in URL userinfo" ;;
    *'?'*)
      case "$url" in
        https://*) ;;
        *) fail "query-bearing $url_name must use HTTPS" ;;
      esac
      ;;
  esac
done

if [ "$CUSTOM_IMAGE" = 1 ]; then
  for url_name in IMAGE_URL CHECKSUM_URL SIGNATURE_URL; do
    eval "url=\${$url_name}"
    case "$url" in
      https://*) ;;
      *) fail "custom mirror $url_name must use HTTPS" ;;
    esac
  done
fi

header_value="${MIRROR_AUTHORIZATION_HEADER-}"
[ "$(printf '%s' "$header_value" | wc -l | tr -d ' ')" = 0 ] \
  || fail "mirror authorization header must be a single line"
carriage_return="$(printf '\r')"
case "$header_value" in
  *"$carriage_return"*) fail "mirror authorization header must not contain carriage returns" ;;
esac

if [ -n "$header_value" ]; then
  header_origin=""
  for url_name in IMAGE_URL CHECKSUM_URL SIGNATURE_URL; do
    eval "url=\${$url_name}"
    case "$url" in
      https://*) ;;
      *) fail "authenticated mirror URLs must use HTTPS" ;;
    esac
    authority="${url#https://}"
    authority="${authority%%/*}"
    authority="${authority%%\?*}"
    [ -n "$authority" ] || fail "authenticated mirror URL authority is empty"
    if [ -z "$header_origin" ]; then
      header_origin="$authority"
    elif [ "$authority" != "$header_origin" ]; then
      fail "authenticated image, checksum, and signature URLs must use the same origin"
    fi
  done
fi

if [ "$SIDECAR_URLS_EXPLICIT" = 0 ]; then
  case "$IMAGE_URL" in
    *'?'*) fail "query-bearing IMAGE_URL requires explicit checksum and signature URLs" ;;
  esac
  [ "$CHECKSUM_URL" = "$IMAGE_URL.sha256" ] || fail "derived checksum URL is inconsistent with IMAGE_URL"
  [ "$SIGNATURE_URL" = "$IMAGE_URL.sha256.asc" ] || fail "derived signature URL is inconsistent with IMAGE_URL"
fi

if [ "$CUSTOM_IMAGE" = 0 ]; then
  case "$EXPECTED_IMAGE_ARCH" in
    x86_64)
      official_url="https://download.opensuse.org/tumbleweed/appliances/openSUSE-MicroOS.x86_64-ContainerHost-OpenStack-Cloud.qcow2"
      ;;
    aarch64)
      official_url="https://download.opensuse.org/ports/aarch64/tumbleweed/appliances/openSUSE-MicroOS.aarch64-ContainerHost-OpenStack-Cloud.qcow2"
      ;;
  esac
  [ "$IMAGE_URL" = "$official_url" ] || fail "official mode requires the exact download.opensuse.org MicroOS appliance URL"
  [ "$CHECKSUM_URL" = "$official_url.sha256" ] || fail "official mode requires the exact openSUSE checksum URL"
  [ "$SIGNATURE_URL" = "$official_url.sha256.asc" ] || fail "official mode requires the exact openSUSE signature URL"
  [ -z "${MIRROR_AUTHORIZATION_HEADER-}" ] || fail "mirror authorization headers are not allowed in official download mode"
fi

expected_digest="$(printf '%s' "${EXPECTED_IMAGE_SHA256-}" | tr '[:upper:]' '[:lower:]')"
[ "${#expected_digest}" -eq 64 ] || fail "every appliance requires a reviewed 64-character EXPECTED_IMAGE_SHA256 pin"
case "$expected_digest" in
  *[!0-9a-f]*) fail "EXPECTED_IMAGE_SHA256 pin is not hexadecimal" ;;
esac

umask 077
work_dir="$(mktemp -d)"
gnupg_home="$work_dir/gnupg"
wget_config="$work_dir/wget.conf"
wget_input="$work_dir/wget.input"
status_file="$work_dir/signature.status"
checksum_file="$work_dir/appliance.sha256"
signature_file="$work_dir/appliance.sha256.asc"
mkdir -m 700 "$gnupg_home"
: > "$wget_config"
: > "$wget_input"
chmod 600 "$wget_config" "$wget_input"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

if [ -n "${MIRROR_AUTHORIZATION_HEADER-}" ]; then
  printf 'header = Authorization: %s\n' "$MIRROR_AUTHORIZATION_HEADER" > "$wget_config"
  unset MIRROR_AUTHORIZATION_HEADER
fi

download() {
  label="$1"
  url="$2"
  destination="$3"
  printf '%s\n' "$url" > "$wget_input"
  # Keep URLs (including redirect targets) private; report only wget's exit category.
  download_status=0
  if [ -s "$wget_config" ]; then
    wget -q --config="$wget_config" --input-file="$wget_input" --max-redirect=0 --dns-timeout=10 --connect-timeout=15 --read-timeout=60 --waitretry=5 --tries=5 --retry-connrefused --inet4-only -O "$destination" \
      2>/dev/null || download_status=$?
  elif [ "$CUSTOM_IMAGE" = 1 ]; then
    wget -q --input-file="$wget_input" --max-redirect=0 --dns-timeout=10 --connect-timeout=15 --read-timeout=60 --waitretry=5 --tries=5 --retry-connrefused --inet4-only -O "$destination" \
      2>/dev/null || download_status=$?
  else
    wget -q --input-file="$wget_input" --dns-timeout=10 --connect-timeout=15 --read-timeout=60 --waitretry=5 --tries=5 --retry-connrefused --inet4-only -O "$destination" \
      2>/dev/null || download_status=$?
  fi
  case "$download_status" in
    0) return ;;
    2) reason="option parsing error" ;;
    3) reason="file I/O error" ;;
    4) reason="network failure (including timeouts)" ;;
    5) reason="TLS certificate verification failure" ;;
    6) reason="authentication failure" ;;
    7) reason="protocol error" ;;
    8) reason="server error response" ;;
    *) reason="download error" ;;
  esac
  fail "failed to download $label (wget exit $download_status: $reason)"
}

[ -r "$OPENSUSE_SIGNING_KEY_FILE" ] || fail "vendored openSUSE signing key is unreadable"

key_record="$(gpg --batch --show-keys --with-colons "$OPENSUSE_SIGNING_KEY_FILE" 2>/dev/null | awk -F: '
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
[ "$(printf '%s\n' "$key_record" | awk 'NF { count++ } END { print count + 0 }')" = 1 ] \
  || fail "openSUSE signing-key set must contain exactly one primary key"

IFS='|' read -r actual_fingerprint key_validity key_created key_expiry key_capabilities <<EOF
$key_record
EOF
[ -n "$key_capabilities" ] || fail "openSUSE signing-key metadata is malformed"
[ "$actual_fingerprint" = "$OPENSUSE_SIGNING_KEY_FINGERPRINT" ] \
  || fail "openSUSE signing key does not match the pinned primary fingerprint"
case "$key_validity" in
  - | u | f | m) ;;
  *) fail "pinned openSUSE signing key is revoked, expired, disabled, or invalid" ;;
esac
case "$key_created:$key_expiry" in
  *[!0-9:]* | :* | *:) fail "pinned openSUSE key lifecycle timestamps are malformed" ;;
esac
case "$key_capabilities" in
  *s* | *S*) ;;
  *) fail "pinned openSUSE primary key is not signing-capable" ;;
esac

now="$(date +%s)"
[ "$key_created" -le $((now + 300)) ] || fail "pinned openSUSE key has a future creation time"
if [ "$key_expiry" != 0 ] && [ "$key_expiry" -le "$now" ]; then
  fail "pinned openSUSE signing key has expired; review and update the vendored trust anchor"
fi

gpg --batch --homedir "$gnupg_home" --import-options import-minimal --import "$OPENSUSE_SIGNING_KEY_FILE" >/dev/null 2>&1 \
  || fail "failed to import the pinned openSUSE signing key"

download "signed appliance checksum" "$CHECKSUM_URL" "$checksum_file"
download "appliance checksum signature" "$SIGNATURE_URL" "$signature_file"

if ! gpg --batch --homedir "$gnupg_home" --status-fd 1 --verify "$signature_file" "$checksum_file" > "$status_file" 2>/dev/null; then
  fail "openSUSE appliance checksum signature verification failed"
fi

awk '
  $1 != "[GNUPG:]" { exit 1 }
  $2 == "NEWSIG" ||
  $2 == "KEY_CONSIDERED" ||
  $2 == "SIG_ID" ||
  $2 == "GOODSIG" ||
  $2 == "VALIDSIG" ||
  $2 ~ /^TRUST_/ { next }
  { exit 1 }
' "$status_file" || fail "checksum verification emitted a non-allowlisted GPG status"

valid_signature_count="$(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { count++ } END { print count + 0 }' "$status_file")"
[ "$valid_signature_count" = 1 ] || fail "checksum must have exactly one VALIDSIG record"

valid_signature="$(awk '
  $1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $3 "|" $5 "|" $6 "|" $12 }
' "$status_file")"
old_ifs=$IFS
IFS='|'
read -r signature_fingerprint signature_created signature_expiry primary_fingerprint <<EOF
$valid_signature
EOF
IFS=$old_ifs

[ "$signature_fingerprint" = "$OPENSUSE_SIGNING_KEY_FINGERPRINT" ] \
  && [ "$primary_fingerprint" = "$OPENSUSE_SIGNING_KEY_FINGERPRINT" ] \
  || fail "checksum signature does not match the pinned primary fingerprint"
case "$signature_created:$signature_expiry" in
  *[!0-9:]* | :* | *:) fail "checksum signature lifecycle timestamps are malformed" ;;
esac
[ "$signature_created" -le $((now + 300)) ] || fail "checksum signature has a future creation time"
if [ "$signature_expiry" -ne 0 ] && [ "$signature_expiry" -le "$now" ]; then
  fail "checksum signature has expired"
fi

image_file="$(awk -v arch="$EXPECTED_IMAGE_ARCH" '
  function valid_digest(value) {
    return length(value) == 64 && value !~ /[^[:xdigit:]]/
  }
  function valid_name(value, expected) {
    expected = "openSUSE-MicroOS." arch "-ContainerHost-OpenStack-Cloud.qcow2"
    return value == expected
  }
  NF == 2 && valid_digest($1) && valid_name($2) {
    matches++
    digest = tolower($1)
    image = $2
  }
  END {
    if (matches == 1) print image "|" digest
    else exit 1
  }
' "$checksum_file")" || fail "signed checksum must identify exactly one safe $EXPECTED_IMAGE_ARCH MicroOS ContainerHost OpenStack image"

image_digest="${image_file#*|}"
image_file="${image_file%%|*}"

[ "$image_digest" = "$expected_digest" ] || fail "signed checksum does not match the reviewed SHA-256 digest pin"

download "MicroOS appliance" "$IMAGE_URL" "$VERIFIED_IMAGE_PATH"
actual_image_digest="$(sha256sum "$VERIFIED_IMAGE_PATH" | awk '{ print tolower($1) }')"
[ "$actual_image_digest" = "$image_digest" ] \
  || fail "MicroOS appliance SHA-256 verification failed"

printf 'Verified openSUSE MicroOS %s ContainerHost OpenStack appliance.\n' "$EXPECTED_IMAGE_ARCH"
