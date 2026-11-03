#!/bin/bash
#
# publish-rauc-bundle.sh -- publish a RAUC bundle to Torizon Cloud as a package
# for the PRIMARY, with its manifest hash attached, and optionally launch it.
#
# WHY THIS EXISTS
#   With the x86 RAUC package manager (docs/rauc-decisions.md D8) the OS bundle is
#   a primary package (hardware id <machine>, NOT <machine>-rootfs), and the device
#   refuses targets without custom.rauc.manifest-hash in the Image repo. The web UI
#   cannot upload primary packages, and neither the UI nor TorizonCore Builder
#   attaches the hash. TEMPORARY: a stopgap until TCB does it (roadmap B17).
#
# WHAT IT DOES
#   1. Gets an app-API token (OAuth2 client credentials).
#   2. Uploads the bundle: POST /packages?name=&version=&hardwareId=&targetFormat=BINARY.
#   3. Attaches the manifest hash: PATCH /packages/<id> with
#      {"proprietaryMeta": {"rauc": {"manifest-hash": "<hash>"}}}, and reads it back.
#   4. With --launch, launches the package to a device (POST /updates) and waits
#      for the device's result (GET /updates/devices/<uuid>).
#
# USAGE
#   publish-rauc-bundle.sh [options] <deploy-dir>/torizon-ab-bundle-<machine>.raucb
#
#   The bundle may be the deploy link or the timestamped file it points to; its
#   manifest hash is read from <bundle>.manifest-hash next to it.
#
# OPTIONS
#   -c, --credentials FILE  API client JSON with client_id, secret, token_endpoint
#   -n, --name NAME         package name        [torizon-ab-bundle-<machine>]
#   -v, --version VERSION   package version     [the bundle's timestamp]
#   -m, --hardware-id ID    primary hardware id [<machine>, from the file name]
#   -l, --launch UUID       launch to this device and wait for the result
#   -h, --help
#
# CREDENTIALS
#   A Torizon Cloud API client allowed to write packages (and updates, for
#   --launch), from a JSON file (--credentials or TORIZON_API_CREDENTIALS) or the
#   environment: TORIZON_CLIENT_ID, TORIZON_CLIENT_SECRET, TORIZON_TOKEN_ENDPOINT
#   (optional). Keep them out of the repository. TORIZON_API overrides the API base.
#
# OUTPUT
#   The package id on stdout, progress on stderr. Exits non-zero on any HTTP error
#   and, with --launch, when the device did not install the package. Interrupting
#   the wait does not cancel the update.

set -euo pipefail

API=${TORIZON_API:-https://app.torizon.io/api/v2}
token_endpoint=${TORIZON_TOKEN_ENDPOINT:-https://kc.torizon.io/auth/realms/ota-users/protocol/openid-connect/token}
POLL_SEC=15

log() { echo "$*" >&2; }
die() { log "publish-rauc-bundle: $*"; exit 1; }
usage() { sed -n '3,/^$/s/^# \{0,1\}//p' "$0"; exit 0; }

creds=${TORIZON_API_CREDENTIALS:-}
name='' version='' hwid='' device=''
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--credentials) creds=${2:?}; shift 2 ;;
        -n|--name)        name=${2:?}; shift 2 ;;
        -v|--version)     version=${2:?}; shift 2 ;;
        -m|--hardware-id) hwid=${2:?}; shift 2 ;;
        -l|--launch)      device=${2:?}; shift 2 ;;
        -h|--help)        usage ;;
        -*)               die "unknown option $1 (see --help)" ;;
        *)                break ;;
    esac
done
[ $# -eq 1 ] || die "usage: publish-rauc-bundle.sh [options] <bundle.raucb> (see --help)"
[ -z "$device" ] || [[ $device =~ ^[0-9a-f-]{36}$ ]] || die "not a device UUID: $device"

# --- Bundle, manifest hash, package coordinates -------------------------------
[ -f "$1" ] || die "no such bundle: $1"
bundle=$(readlink -f "$1")
[ -r "$bundle.manifest-hash" ] || die "no manifest hash next to the bundle: $bundle.manifest-hash"
hash=$(tr -d '[:space:]' < "$bundle.manifest-hash")
[[ $hash =~ ^[0-9a-f]{64}$ ]] || die "not a manifest hash in $bundle.manifest-hash: $hash"

# torizon-ab-bundle-<machine>-<timestamp>.raucb
file=${bundle##*/}
if [[ ${file%.raucb} =~ ^(.+)-([0-9]{14})$ ]]; then
    base=${BASH_REMATCH[1]} stamp=${BASH_REMATCH[2]}
    name=${name:-$base}
    version=${version:-$stamp}
    case "$base" in torizon-ab-bundle-*) hwid=${hwid:-${base#torizon-ab-bundle-}} ;; esac
fi
for v in name version hwid; do
    [ -n "${!v}" ] || die "cannot derive the package $v from $file, pass it as an option"
    [[ ${!v} =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid package $v: ${!v}"
done

# --- HTTP ---------------------------------------------------------------------
# Secrets go through files in $tmp (mode 0600), never on a command line.
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# http METHOD URL [curl args...]: the response body on stdout; dies on an HTTP error.
http() {
    local method=$1 url=$2 code
    shift 2
    code=$(curl -sS -o "$tmp/body" -w '%{http_code}' -X "$method" "$@" "$url") \
        || die "$method ${url%%\?*}: request failed"
    if [ "$code" -ge 400 ]; then
        log "$(cat "$tmp/body")"
        die "$method ${url%%\?*}: HTTP $code"
    fi
    cat "$tmp/body"
}

# api METHOD PATH [curl args...]: an app-API call with the token.
api() {
    local method=$1 path=$2
    shift 2
    http "$method" "$API$path" -H "@$tmp/auth" "$@"
}

# json FILE EXPR [ARG...]: evaluate a Python expression over the JSON document 'd'
# in FILE; the ARGs are sys.argv[3:].
json() {
    python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$@"
}

# --- Token --------------------------------------------------------------------
if [ -n "$creds" ]; then
    [ -r "$creds" ] || die "cannot read the credentials file $creds"
    client_id=$(json "$creds" 'd["client_id"]')
    secret=$(json "$creds" 'd.get("secret") or d["client_secret"]')
    endpoint=$(json "$creds" 'd.get("token_endpoint") or ""')
    token_endpoint=${endpoint:-$token_endpoint}
else
    client_id=${TORIZON_CLIENT_ID:-}
    secret=${TORIZON_CLIENT_SECRET:-}
fi
[ -n "$client_id" ] && [ -n "$secret" ] \
    || die "no API client: set TORIZON_API_CREDENTIALS or TORIZON_CLIENT_ID/TORIZON_CLIENT_SECRET"
printf %s "$secret" > "$tmp/secret"

http POST "$token_endpoint" --data-urlencode grant_type=client_credentials \
    --data-urlencode "client_id=$client_id" --data-urlencode "client_secret@$tmp/secret" > "$tmp/token"
printf 'Authorization: Bearer %s\n' "$(json "$tmp/token" 'd["access_token"]')" > "$tmp/auth"

# --- Upload + manifest hash ---------------------------------------------------
log "Uploading $file ($(($(wc -c < "$bundle") / 1048576)) MiB) as $name $version for $hwid..."
start=$SECONDS
api POST "/packages?name=$name&version=$version&hardwareId=$hwid&targetFormat=BINARY" \
    -H 'Content-Type: application/octet-stream' -T "$bundle" > "$tmp/package"
id=$(json "$tmp/package" 'd["packageId"]')
log "Uploaded $id in $((SECONDS - start)) s"

api PATCH "/packages/$id" -H 'Content-Type: application/json' \
    -d "{\"proprietaryMeta\":{\"rauc\":{\"manifest-hash\":\"$hash\"}}}" > /dev/null
api GET "/packages/$id" > "$tmp/package"
[ "$(json "$tmp/package" 'd["proprietaryMeta"]["rauc"]["manifest-hash"]')" = "$hash" ] \
    || die "$id: the manifest hash did not stick"
log "Attached manifest hash $hash"
echo "$id"

[ -n "$device" ] || exit 0

# --- Launch + wait ------------------------------------------------------------
api POST /updates -H 'Content-Type: application/json' \
    -d "{\"packageIds\":[\"$id\"],\"devices\":[\"$device\"]}" > "$tmp/launch"
[ "$(json "$tmp/launch" 'len(d.get("affected") or [])')" -gt 0 ] \
    || die "launching $id did not affect device $device: $(cat "$tmp/launch")"
log "Launched to $device, waiting for its result (streaming a full bundle takes minutes)..."

# The device's newest update of this package: status, success, description. The
# status is "Completed" also when the install failed; deviceResult tells.
last=''
while :; do
    api GET "/updates/devices/$device" > "$tmp/updates"
    result=$(json "$tmp/updates" '"\t".join(map(str, next(
        ([u["status"], (u.get("deviceResult") or {}).get("success"), (u.get("deviceResult") or {}).get("description")]
         for u in d["values"] if sys.argv[3] in u["packages"].values()), ["Unknown", None, None])))' "$id")
    IFS=$'\t' read -r status success desc <<< "$result"
    [ "$status" = "$last" ] || log "$(date -u +%H:%M:%S) $status"
    last=$status
    case "$status" in
        Completed|Failed|Cancel*) break ;;
    esac
    sleep "$POLL_SEC"
done
[ "$success" = True ] || die "update of $device with $id: $status: $desc"
log "Installed: $desc"
