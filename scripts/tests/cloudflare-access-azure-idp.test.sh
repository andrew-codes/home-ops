#!/usr/bin/env bash
#
# Tests scripts/bin/cloudflare-access-azure-idp.sh without touching Cloudflare
# or Azure.
#
# The script needs a live Cloudflare account and a signed-in az session, and its
# fixes rotate a real client secret, so none of it can be exercised for real
# from a test. `az` and `curl` are replaced by stub commands on PATH that serve
# canned JSON from a per-case fixture directory and log every call they get. A
# real `jq` is used. Nothing outside this script's own temp directory is
# written.
#
# Run it after any change to the script:
#
#   scripts/tests/cloudflare-access-azure-idp.test.sh
#
# Requires jq.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TESTS_DIR/../bin/cloudflare-access-azure-idp.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP  cloudflare-access-azure-idp tests: jq is not installed"
  exit 0
fi

# A secret that would be unmistakable if it ever leaked into output, a log, an
# argument list or a temp file.
SENTINEL="S3nt1nel-Cl13nt-S3cret-do-not-log"
TOKEN="cf-test-token_0123456789"

# 2026-09-30T00:00:00Z, so expiry maths does not depend on the day this runs.
NOW=1790726400

TENANT="11111111-1111-1111-1111-111111111111"
CLIENT="22222222-2222-2222-2222-222222222222"
ACCOUNT="acc00000000000000000000000000001"
IDP="33333333-3333-3333-3333-333333333333"
GRAPH_SP="44444444-4444-4444-4444-444444444444"
APP_SP="55555555-5555-5555-5555-555555555555"

passes=0
failures=0

ok() {
  echo "  PASS  $1"
  passes=$((passes + 1))
}

fail() {
  echo "  FAIL  $1"
  echo "        $2"
  failures=$((failures + 1))
}

check() { # description, expected, actual
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

has() { # description, needle, haystack
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) fail "$1" "missing '$2' in: $3" ;;
  esac
}

lacks() { # description, needle, haystack
  case "$3" in
    *"$2"*) fail "$1" "unexpected '$2' in: $3" ;;
    *) ok "$1" ;;
  esac
}

# ---- stub commands ---------------------------------------------------------

STUBS="$WORK/stubs"
mkdir -p "$STUBS"

cat >"$STUBS/az" <<'STUB'
#!/usr/bin/env bash
# Fake az. Serves fixtures from $FIX, logs every call (arguments only).
echo "az $*" >>"$STUB_LOG/az.log"
case "$*" in
  "account show"*)
    [ -f "$FIX/az_signed_out" ] && { echo "ERROR: Please run 'az login' to setup account." >&2; exit 1; }
    cat "$FIX/az_account.json" ;;
  "ad app show"*)
    [ -f "$FIX/az_app.json" ] || { echo "ERROR: Resource does not exist" >&2; exit 1; }
    cat "$FIX/az_app.json" ;;
  "ad app credential list"*) cat "$FIX/az_creds.json" ;;
  "ad app credential reset"*)
    [ -f "$FIX/az_reset_fails" ] && { echo "ERROR: Insufficient privileges" >&2; exit 1; }
    # Like the real command: the new secret is on stdout, and it becomes a credential.
    jq '. + [{"displayName":"new","endDateTime":"2028-09-30T00:00:00Z","keyId":"new-key","hint":"new","startDateTime":"2026-09-30T00:00:00Z"}]' \
      "$FIX/az_creds.json" >"$FIX/az_creds.json.new" && mv "$FIX/az_creds.json.new" "$FIX/az_creds.json"
    # Rename the new credential to the display name that was asked for.
    name=""; prev=""
    for a in "$@"; do [ "$prev" = "--display-name" ] && name="$a"; prev="$a"; done
    jq --arg n "$name" 'map(if .keyId == "new-key" then .displayName = $n else . end)' \
      "$FIX/az_creds.json" >"$FIX/az_creds.json.new" && mv "$FIX/az_creds.json.new" "$FIX/az_creds.json"
    printf '{"appId":"x","password":"%s","tenant":"t"}\n' "$SENTINEL" ;;
  "ad sp show --id 00000003-0000-0000-c000-000000000000"*) cat "$FIX/az_graph_sp.json" ;;
  "ad sp show"*)
    [ -f "$FIX/az_sp.json" ] || { echo "ERROR: Resource does not exist" >&2; exit 1; }
    cat "$FIX/az_sp.json" ;;
  "ad app permission list-grants"*) cat "$FIX/az_grants.json" ;;
  "ad app permission admin-consent"*)
    [ -f "$FIX/az_consent_fails" ] && { echo "ERROR: Authorization_RequestDenied" >&2; exit 1; }
    [ -f "$FIX/az_grants_after.json" ] && cp "$FIX/az_grants_after.json" "$FIX/az_grants.json"
    echo '{}' ;;
  "rest "*) cat "$FIX/az_roles.json" ;;
  *) echo "stub az: unhandled: $*" >&2; exit 99 ;;
esac
STUB

cat >"$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
# Fake curl. Understands the handful of flags the script uses.
echo "curl $*" >>"$STUB_LOG/curl.log"
method=GET url="" cfg="" data=0
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -K) cfg="$2"; shift 2 ;;
    -H | -w) shift 2 ;;
    --data-binary) data=1; shift 2 ;;
    -sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
if grep -q "Authorization: Bearer $EXPECT_TOKEN" "$cfg" 2>/dev/null; then auth=ok; else auth=bad; fi
echo "$method ${url#https://api.cloudflare.com/client/v4} auth=$auth" >>"$STUB_LOG/requests.log"
if [ "$data" = 1 ]; then
  n=$(($(ls "$STUB_LOG"/put.*.json 2>/dev/null | wc -l) + 1))
  cat >"$STUB_LOG/put.$n.json"
fi
path="${url#https://api.cloudflare.com/client/v4}"
reply() { cat "$FIX/$1"; printf '\n%s' "${2:-200}"; }
case "$method $path" in
  "GET /accounts?"*) reply cf_accounts.json ;;
  "GET /accounts/"*"/access/identity_providers?"*)
    if [ -f "$FIX/cf_idps_forbidden" ]; then reply cf_idps.json 403; else reply cf_idps.json; fi ;;
  "GET /accounts/"*"/access/identity_providers/"*) reply cf_idp.json ;;
  "GET /accounts/"*"/access/organizations") reply cf_org.json ;;
  "PUT /accounts/"*"/access/identity_providers/"*)
    if [ -f "$FIX/cf_put_fails" ]; then reply cf_put_error.json 403; else reply cf_put_ok.json; fi ;;
  "GET "*) reply cf_list_forbidden.json 403 ;;
  *) echo "stub curl: unhandled: $method $path" >&2; exit 99 ;;
esac
STUB
chmod +x "$STUBS/az" "$STUBS/curl"

# ---- fixtures --------------------------------------------------------------

# A healthy baseline: one azureAD provider with groups on, an app with every
# documented Graph delegated permission admin-consented, a valid secret and an
# expired one. Cases then break one thing each.
new_case() { # name
  CASE="$WORK/case-$1"
  FIX="$CASE/fix"
  STUB_LOG="$CASE/log"
  TMPD="$CASE/tmp"
  mkdir -p "$FIX" "$STUB_LOG" "$TMPD"

  echo '{"success":true,"result":[{"id":"'"$ACCOUNT"'","name":"Home"}]}' >"$FIX/cf_accounts.json"
  jq -n --arg idp "$IDP" --arg client "$CLIENT" --arg tenant "$TENANT" '{success:true, result:[
    {id:$idp, name:"Microsoft", type:"azureAD"},
    {id:"99999999-9999-9999-9999-999999999999", name:"One-time PIN", type:"onetimepin"}]}' >"$FIX/cf_idps.json"
  jq -n --arg idp "$IDP" --arg client "$CLIENT" --arg tenant "$TENANT" '{success:true, result:
    {id:$idp, name:"Microsoft", type:"azureAD",
     config:{client_id:$client, client_secret:"**masked**", directory_id:$tenant, support_groups:true,
             email_claim_name:"email", claims:["upn"], prompt:"select_account", conditional_access_enabled:false},
     scim_config:{enabled:false}}}' >"$FIX/cf_idp.json"
  echo '{"success":true,"result":{"auth_domain":"example.cloudflareaccess.com"}}' >"$FIX/cf_org.json"
  echo '{"success":true,"result":{"id":"'"$IDP"'"}}' >"$FIX/cf_put_ok.json"
  echo '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"result":null}' >"$FIX/cf_put_error.json"
  echo '{"success":false,"errors":[{"code":9109,"message":"Unauthorized to access requested resource"}],"result":null}' >"$FIX/cf_list_forbidden.json"

  jq -n --arg t "$TENANT" '{tenantId:$t, user:{name:"captain@example.com"}}' >"$FIX/az_account.json"
  jq -n --arg c "$CLIENT" '{id:"66666666-6666-6666-6666-666666666666", appId:$c, displayName:"Cloudflare Access",
    requiredResourceAccess:[{resourceAppId:"00000003-0000-0000-c000-000000000000", resourceAccess:[
      {id:"e1fe6dd8-ba31-4d61-89e7-88639da4683d", type:"Scope"},
      {id:"37f7f235-527c-4136-accd-4a02d197296e", type:"Scope"},
      {id:"14dad69e-099b-42c9-810b-d002981feec1", type:"Scope"},
      {id:"64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0", type:"Scope"},
      {id:"7427e0e9-2fba-42fe-b0c0-848c9e6a8182", type:"Scope"},
      {id:"bc024368-1153-4739-b217-4326f2e966d0", type:"Scope"},
      {id:"06da0dbc-49e2-44d2-8312-53f166ab848a", type:"Scope"}]}]}' >"$FIX/az_app.json"
  cat >"$FIX/az_creds.json" <<'JSON'
[
  {"displayName":"current","endDateTime":"2027-06-01T00:00:00Z","keyId":"key-current","hint":"abc","startDateTime":"2025-06-01T00:00:00Z"},
  {"displayName":"old-2025","endDateTime":"2026-09-01T00:00:00Z","keyId":"key-old","hint":"xyz","startDateTime":"2024-09-01T00:00:00Z"}
]
JSON
  jq -n --arg g "$GRAPH_SP" '{id:$g,
    oauth2PermissionScopes:[
      {id:"e1fe6dd8-ba31-4d61-89e7-88639da4683d", value:"User.Read"},
      {id:"37f7f235-527c-4136-accd-4a02d197296e", value:"openid"},
      {id:"14dad69e-099b-42c9-810b-d002981feec1", value:"profile"},
      {id:"64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0", value:"email"},
      {id:"7427e0e9-2fba-42fe-b0c0-848c9e6a8182", value:"offline_access"},
      {id:"bc024368-1153-4739-b217-4326f2e966d0", value:"GroupMember.Read.All"},
      {id:"06da0dbc-49e2-44d2-8312-53f166ab848a", value:"Directory.Read.All"}],
    appRoles:[
      {id:"7ab1d382-f21e-4acd-a863-ba3e13f7da61", value:"Directory.Read.All"},
      {id:"98830695-27a2-44f7-8c18-0c3ebc9698f6", value:"GroupMember.Read.All"}]}' >"$FIX/az_graph_sp.json"
  echo '{"id":"'"$APP_SP"'","accountEnabled":true}' >"$FIX/az_sp.json"
  jq -n --arg g "$GRAPH_SP" '[{consentType:"AllPrincipals", resourceId:$g,
    scope:"User.Read openid profile email offline_access GroupMember.Read.All Directory.Read.All"}]' >"$FIX/az_grants.json"
  echo '{"value":[]}' >"$FIX/az_roles.json"
}

# Edit a fixture in place with a jq filter.
edit() { # file filter
  jq "$2" "$FIX/$1" >"$FIX/$1.new" && mv "$FIX/$1.new" "$FIX/$1"
}

# Run the script. Sets OUT (stdout+stderr), RC. Extra args are script flags.
# Stdin is /dev/null unless STDIN_TEXT is set.
run() {
  : >"$STUB_LOG/az.log"
  : >"$STUB_LOG/curl.log"
  : >"$STUB_LOG/requests.log"
  OUT="$(
    printf '%s' "${STDIN_TEXT-}" | env PATH="$STUBS:$PATH" FIX="$FIX" STUB_LOG="$STUB_LOG" SENTINEL="$SENTINEL" \
      EXPECT_TOKEN="$TOKEN" CLOUDFLARE_API_TOKEN="${TOKEN_OVERRIDE-$TOKEN}" CFAZ_NOW_EPOCH="$NOW" TMPDIR="$TMPD" \
      CLOUDFLARE_ACCOUNT_ID="${ACCOUNT_ENV-$ACCOUNT}" bash "$SCRIPT" "$@" 2>&1
  )"
  RC=$?
  STDIN_TEXT=""
}

az_calls() { grep -c -- "$1" "$STUB_LOG/az.log"; }
cf_puts() { grep -c '^PUT ' "$STUB_LOG/requests.log"; }

# Nothing in the read-only path may mutate anything.
assert_read_only() {
  check "$1: no secret created" "0" "$(az_calls 'credential reset')"
  check "$1: no consent granted" "0" "$(az_calls 'admin-consent')"
  check "$1: no secret deleted" "0" "$(az_calls 'credential delete')"
  check "$1: nothing written to Cloudflare" "0" "$(cf_puts)"
}

verdict_of() { printf '%s\n' "$OUT" | sed -n 's/^VERDICT: //p'; }

# ---- diagnose --------------------------------------------------------------

echo "== diagnose: verdicts"

new_case healthy
run
check "healthy: exit 0" "0" "$RC"
check "healthy: verdict" "STALE_SECRET_SUSPECTED" "$(verdict_of)"
has "healthy: names the provider" "Microsoft ($IDP)" "$OUT"
has "healthy: shows the team domain" "example.cloudflareaccess.com" "$OUT"
has "healthy: lists the valid secret with expiry" "expires 2027-06-01" "$OUT"
has "healthy: lists the expired secret" "expired    expires 2026-09-01" "$OUT"
has "healthy: says which CF fields match" "client id in Cloudflare matches" "$OUT"
has "healthy: says tenant matches" "directory (tenant) id matches" "$OUT"
has "healthy: mentions expired secret as a candidate" "1 expired secret(s) exist" "$OUT"
has "healthy: says it changed nothing" "nothing was changed" "$OUT"
check "healthy: every Cloudflare call used the token" "0" "$(grep -c 'auth=bad' "$STUB_LOG/requests.log")"
assert_read_only "healthy"

new_case expired
echo '[{"displayName":"a","endDateTime":"2026-09-29T23:59:59Z","keyId":"k1","startDateTime":"2025-01-01T00:00:00Z"}]' >"$FIX/az_creds.json"
run
check "expired: exit 2" "2" "$RC"
check "expired: verdict" "EXPIRED_SECRET" "$(verdict_of)"
has "expired: fail line" "no unexpired client secret on the app (1 expired)" "$OUT"
assert_read_only "expired"

new_case no-secrets
echo '[]' >"$FIX/az_creds.json"
run
check "no secrets: verdict" "EXPIRED_SECRET" "$(verdict_of)"
has "no secrets: says so" "no client secrets on this app" "$OUT"

new_case expiring
echo '[{"displayName":"a","endDateTime":"2026-10-15T00:00:00Z","keyId":"k1","startDateTime":"2025-01-01T00:00:00Z"}]' >"$FIX/az_creds.json"
run
has "expiring: warns" "every unexpired secret expires within 30 days" "$OUT"
has "expiring: shows days left" "(15d)" "$OUT"
check "expiring: not the verdict, nothing else is wrong" "STALE_SECRET_SUSPECTED" "$(verdict_of)"
run --warn-days 10
has "expiring: --warn-days moves the threshold" "valid for more than 10 days" "$OUT"

new_case expiry-boundary
echo '[{"displayName":"a","endDateTime":"2026-09-30T00:00:00Z","keyId":"k1","startDateTime":"2025-01-01T00:00:00Z"}]' >"$FIX/az_creds.json"
run
check "expiry at exactly now counts as expired" "EXPIRED_SECRET" "$(verdict_of)"

new_case recent-secret
edit az_creds.json '.[0].startDateTime = "2026-09-25T00:00:00Z"'
run
has "recent secret: hints at a rotation" "created in the last 14 days" "$OUT"

new_case older-cli-shape
echo '[{"displayName":"a","endDate":"2027-01-01T00:00:00.000000+00:00","keyId":"k1","startDate":"2025-01-01T00:00:00.000000+00:00"}]' >"$FIX/az_creds.json"
run
has "older az output (endDate, fractional, +00:00) is understood" "expires 2027-01-01" "$OUT"

new_case consent-lost
edit az_grants.json '.[0].scope = "User.Read openid profile email offline_access"'
run
check "consent lost: exit 2" "2" "$RC"
check "consent lost: verdict" "PERMISSIONS" "$(verdict_of)"
has "consent lost: names the fix" "--grant-admin-consent" "$OUT"
has "consent lost: says what is missing" "neither GroupMember.Read.All nor Directory.Read.All is admin-consented" "$OUT"
assert_read_only "consent lost"

new_case user-read-unconsented
edit az_grants.json '.[0].consentType = "Principal"'
run
check "user-only consent is not admin consent" "PERMISSIONS" "$(verdict_of)"
has "user-only consent: fail line" "User.Read: requested but NOT admin-consented" "$OUT"

new_case user-read-not-requested
edit az_app.json '.requiredResourceAccess[0].resourceAccess |= map(select(.id != "e1fe6dd8-ba31-4d61-89e7-88639da4683d"))'
run
check "User.Read missing: verdict" "PERMISSIONS" "$(verdict_of)"
has "User.Read missing: says to add it" "Add it" "$OUT"

new_case groups-off
edit cf_idp.json '.result.config.support_groups = false'
edit az_app.json '.requiredResourceAccess[0].resourceAccess |= map(select(.id != "bc024368-1153-4739-b217-4326f2e966d0" and .id != "06da0dbc-49e2-44d2-8312-53f166ab848a"))'
edit az_grants.json '.[0].scope = "User.Read openid profile email offline_access"'
run
check "groups off: group permissions are not required" "STALE_SECRET_SUSPECTED" "$(verdict_of)"

new_case groups-on-not-requested
edit az_app.json '.requiredResourceAccess[0].resourceAccess |= map(select(.id != "bc024368-1153-4739-b217-4326f2e966d0" and .id != "06da0dbc-49e2-44d2-8312-53f166ab848a"))'
edit az_grants.json '.[0].scope = "User.Read openid profile email offline_access"'
run
check "groups on, none requested: verdict" "PERMISSIONS" "$(verdict_of)"
has "groups on, none requested: says to add" "not even requested" "$OUT"

new_case directory-read-is-enough
edit az_grants.json '.[0].scope = "User.Read openid profile email offline_access Directory.Read.All"'
run
check "Directory.Read.All alone satisfies groups" "STALE_SECRET_SUSPECTED" "$(verdict_of)"
has "GroupMember.Read.All is still flagged as part of the documented set" "GroupMember.Read.All: requested but not admin-consented" "$OUT"

new_case app-role-consented
edit az_app.json '.requiredResourceAccess[0].resourceAccess += [{id:"7ab1d382-f21e-4acd-a863-ba3e13f7da61", type:"Role"}]'
edit az_grants.json '.[0].scope = "User.Read openid profile email offline_access"'
echo '{"value":[{"appRoleId":"7ab1d382-f21e-4acd-a863-ba3e13f7da61","resourceId":"'"$GRAPH_SP"'"}]}' >"$FIX/az_roles.json"
edit az_app.json '.requiredResourceAccess[0].resourceAccess |= map(select(.id != "bc024368-1153-4739-b217-4326f2e966d0" and .id != "06da0dbc-49e2-44d2-8312-53f166ab848a"))'
run
check "application permission with a role assignment counts" "STALE_SECRET_SUSPECTED" "$(verdict_of)"
has "application permission: reads role assignments" "appRoleAssignments" "$(cat "$STUB_LOG/az.log")"

new_case app-role-unconsented
edit az_app.json '.requiredResourceAccess[0].resourceAccess |= (map(select(.id != "bc024368-1153-4739-b217-4326f2e966d0" and .id != "06da0dbc-49e2-44d2-8312-53f166ab848a")) + [{id:"7ab1d382-f21e-4acd-a863-ba3e13f7da61", type:"Role"}])'
edit az_grants.json '.[0].scope = "User.Read openid profile email offline_access"'
run
check "application permission without a role assignment does not" "PERMISSIONS" "$(verdict_of)"

new_case tenant-mismatch
edit az_account.json '.tenantId = "77777777-7777-7777-7777-777777777777"'
run
check "tenant mismatch: exit 2" "2" "$RC"
check "tenant mismatch: verdict" "TENANT_MISMATCH" "$(verdict_of)"
has "tenant mismatch: says how to sign in" "az login --tenant $TENANT" "$OUT"

new_case tenant-case-insensitive
edit az_account.json '.tenantId |= ascii_upcase'
run
check "tenant ids compare case-insensitively" "STALE_SECRET_SUSPECTED" "$(verdict_of)"

new_case client-id-mismatch
run --app-id 88888888-8888-8888-8888-888888888888
check "client id mismatch: verdict" "CLIENT_ID_MISMATCH" "$(verdict_of)"
has "client id mismatch: names both ids" "Cloudflare uses $CLIENT but --app-id/AZURE_APP_ID is 88888888" "$OUT"
check "client id mismatch: azure looked up the id it was given" "1" "$(az_calls 'ad app show --id 88888888-8888-8888-8888-888888888888')"

new_case client-id-same-via-env
run --app-id "$CLIENT"
check "an --app-id equal to Cloudflare's is not a mismatch" "STALE_SECRET_SUSPECTED" "$(verdict_of)"

new_case app-not-found
rm "$FIX/az_app.json"
run
check "app not found: exit 2" "2" "$RC"
check "app not found: verdict" "APP_NOT_FOUND" "$(verdict_of)"
has "app not found: shows az's error" "Resource does not exist" "$OUT"
assert_read_only "app not found"

new_case no-service-principal
rm "$FIX/az_sp.json"
run
check "no service principal: verdict" "NO_SERVICE_PRINCIPAL" "$(verdict_of)"
has "no service principal: says how to create it" "az ad sp create --id $CLIENT" "$OUT"

new_case sp-disabled
echo '{"id":"'"$APP_SP"'","accountEnabled":false}' >"$FIX/az_sp.json"
run
check "disabled service principal: verdict" "NO_SERVICE_PRINCIPAL" "$(verdict_of)"

new_case several-problems
echo '[]' >"$FIX/az_creds.json"
edit az_grants.json '.[0].scope = "openid"'
run
check "several problems: the expired secret leads" "EXPIRED_SECRET" "$(verdict_of)"
has "several problems: the rest are still reported" "ALSO:    PERMISSIONS" "$OUT"

# ---- discovery, prerequisites, errors --------------------------------------

echo "== discovery and prerequisites"

new_case discover-account
ACCOUNT_ENV="" run
check "discovers the only account" "STALE_SECRET_SUSPECTED" "$(verdict_of)"
has "discovery listed accounts" "GET /accounts?" "$(cat "$STUB_LOG/requests.log")"

new_case several-accounts
echo '{"success":true,"result":[{"id":"a1","name":"One"},{"id":"a2","name":"Two"}]}' >"$FIX/cf_accounts.json"
ACCOUNT_ENV="" run
check "several accounts: exit 1" "1" "$RC"
has "several accounts: asks for --account-id" "pass --account-id" "$OUT"
has "several accounts: lists them" "a2  Two" "$OUT"

new_case no-account-permission
ACCOUNT_ENV="" run
mv "$FIX/cf_accounts.json" "$FIX/x"
echo '{"success":false,"errors":[{"code":9109,"message":"Unauthorized to access requested resource"}]}' >"$FIX/cf_accounts.json"
ACCOUNT_ENV="" run
check "account listing denied: exit 1" "1" "$RC"
has "account listing denied: suggests --account-id" "pass --account-id" "$OUT"

new_case multi-idp
jq '.result += [{id:"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", name:"Second Azure", type:"azureAD"}]' "$FIX/cf_idps.json" >"$FIX/x" && mv "$FIX/x" "$FIX/cf_idps.json"
run
check "several azureAD providers: exit 1" "1" "$RC"
has "several azureAD providers: asks for --idp" "pass --idp" "$OUT"
has "several azureAD providers: lists them" "Second Azure" "$OUT"
run --idp Microsoft
check "--idp selects by name" "STALE_SECRET_SUSPECTED" "$(verdict_of)"
run --idp "$IDP"
check "--idp selects by id" "STALE_SECRET_SUSPECTED" "$(verdict_of)"
run --idp nonexistent
check "--idp with no match: exit 1" "1" "$RC"

new_case no-azure-idp
echo '{"success":true,"result":[{"id":"99","name":"One-time PIN","type":"onetimepin"}]}' >"$FIX/cf_idps.json"
run
check "no azureAD provider: exit 1" "1" "$RC"
has "no azureAD provider: says so" "no azureAD identity provider" "$OUT"
has "no azureAD provider: lists what exists" "onetimepin" "$OUT"

new_case cf-forbidden
echo '{"success":false,"errors":[{"code":9109,"message":"Unauthorized to access requested resource"}]}' >"$FIX/cf_idps.json"
touch "$FIX/cf_idps_forbidden"
run
check "Cloudflare 403: exit 1" "1" "$RC"
has "Cloudflare 403: shows Cloudflare's error" "Unauthorized to access requested resource" "$OUT"
has "Cloudflare 403: points at token permissions" "the token needs the Access identity provider permissions" "$OUT"

new_case signed-out
touch "$FIX/az_signed_out"
run
check "az signed out: exit 1" "1" "$RC"
has "az signed out: says to log in" "az login" "$OUT"

new_case no-token
TOKEN_OVERRIDE="" run
check "no token: exit 1" "1" "$RC"
has "no token: says so" "CLOUDFLARE_API_TOKEN is not set" "$OUT"
check "no token: nothing was called" "0" "$(wc -l <"$STUB_LOG/curl.log" | tr -d ' ')"

new_case odd-token
TOKEN_OVERRIDE='abc"; evil' run
check "token with odd characters is refused" "1" "$RC"
check "odd token: nothing was called" "0" "$(wc -l <"$STUB_LOG/curl.log" | tr -d ' ')"
unset TOKEN_OVERRIDE

new_case no-az
NOAZ="$WORK/noaz-bin"
mkdir -p "$NOAZ"
for t in bash jq mktemp rm sed head tr date cat mv wc ls grep; do ln -sf "$(command -v "$t")" "$NOAZ/$t"; done
ln -sf "$STUBS/curl" "$NOAZ/curl"
out="$(env PATH="$NOAZ" CLOUDFLARE_API_TOKEN="$TOKEN" "$(command -v bash)" "$SCRIPT" 2>&1)"
rc=$?
check "missing az: exit 1" "1" "$rc"
has "missing az: names the tool" "required tool not found on PATH: az" "$out"

new_case xtrace
out="$(env PATH="$STUBS:$PATH" CLOUDFLARE_API_TOKEN="$TOKEN" bash -x "$SCRIPT" 2>&1)"
rc=$?
check "refuses to run under xtrace: exit 1" "1" "$rc"
has "refuses to run under xtrace: says why" "refusing to run with xtrace" "$out"

new_case help
run --help
check "--help: exit 0" "0" "$RC"
has "--help documents the rotate flag" "--rotate-secret" "$OUT"
has "--help documents token scopes" "Access: Organizations, Identity Providers, and Groups" "$OUT"
check "--help calls nothing" "0" "$(wc -l <"$STUB_LOG/curl.log" | tr -d ' ')"
run --bogus
check "unknown flag: exit 1" "1" "$RC"

# ---- fix: rotate the client secret -----------------------------------------

echo "== fix: --rotate-secret"

# Nothing ever reveals the secret: output, every argument list, temp files.
assert_no_leak() { # label
  lacks "$1: secret not in output" "$SENTINEL" "$OUT"
  lacks "$1: secret not in any az argument list" "$SENTINEL" "$(cat "$STUB_LOG/az.log")"
  lacks "$1: secret not in any curl argument list" "$SENTINEL" "$(cat "$STUB_LOG/curl.log")"
  lacks "$1: secret not in the curl config that carried the token" "$SENTINEL" "$(cat "$STUB_LOG/requests.log")"
  check "$1: nothing left in the temp dir" "" "$(ls -A "$TMPD")"
  lacks "$1: API token not in any argument list" "$TOKEN" "$(cat "$STUB_LOG/curl.log")"
}

new_case rotate-no-answer
run --rotate-secret
check "no confirmation: exit 0" "0" "$RC"
has "no confirmation: shows the az step" "az ad app credential reset --id $CLIENT --append --display-name cloudflare-access-20260930-000000 --years 2" "$OUT"
has "no confirmation: shows the Cloudflare step" "PUT https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/access/identity_providers/$IDP" "$OUT"
has "no confirmation: promises the old secrets stay" "keeps the 2 existing secret(s)" "$OUT"
has "no confirmation: says it did not change anything" "Not confirmed. Nothing changed." "$OUT"
assert_read_only "no confirmation"
assert_no_leak "no confirmation"

new_case rotate-declined
STDIN_TEXT="n" run --rotate-secret
has "declined: nothing changed" "Not confirmed. Nothing changed." "$OUT"
assert_read_only "declined"

new_case rotate-dry-run
run --rotate-secret --dry-run --yes
check "dry run beats --yes: exit 0" "0" "$RC"
has "dry run: says so" "Dry run: no changes made." "$OUT"
assert_read_only "dry run"

new_case rotate-accepted
STDIN_TEXT="y" run --rotate-secret
check "accepted on stdin: exit 0" "0" "$RC"
check "accepted: one secret created" "1" "$(az_calls 'credential reset')"
has "accepted: secret is appended" "--append" "$(grep 'credential reset' "$STUB_LOG/az.log")"
has "accepted: named and dated" "--display-name cloudflare-access-20260930-000000" "$(grep 'credential reset' "$STUB_LOG/az.log")"
check "accepted: exactly one PUT" "1" "$(cf_puts)"
check "accepted: PUT went to the provider" "PUT /accounts/$ACCOUNT/access/identity_providers/$IDP auth=ok" "$(grep '^PUT ' "$STUB_LOG/requests.log")"
put="$STUB_LOG/put.1.json"
check "accepted: new secret reached Cloudflare" "$SENTINEL" "$(jq -r '.config.client_secret' "$put")"
check "accepted: client id preserved" "$CLIENT" "$(jq -r '.config.client_id' "$put")"
check "accepted: directory id preserved" "$TENANT" "$(jq -r '.config.directory_id' "$put")"
check "accepted: groups setting preserved" "true" "$(jq -r '.config.support_groups' "$put")"
check "accepted: email claim preserved" "email" "$(jq -r '.config.email_claim_name' "$put")"
check "accepted: claims preserved" '["upn"]' "$(jq -c '.config.claims' "$put")"
check "accepted: prompt preserved" "select_account" "$(jq -r '.config.prompt' "$put")"
check "accepted: conditional access preserved" "false" "$(jq -r '.config.conditional_access_enabled' "$put")"
check "accepted: name and type preserved" "Microsoft azureAD" "$(jq -r '"\(.name) \(.type)"' "$put")"
check "accepted: masked secret from the GET is not sent back" "1" "$(grep -c "$SENTINEL" "$put")"
lacks "accepted: masked placeholder not sent" "masked" "$(cat "$put")"
has "accepted: says the secret was not printed" "was NOT printed, logged, or written anywhere" "$OUT"
has "accepted: lists the new secret" "NEW     valid    expires 2028-09-30  cloudflare-access-20260930-000000" "$OUT"
has "accepted: lists the old secret with its expiry for removal" "old     valid    expires 2027-06-01  current" "$OUT"
has "accepted: lists the expired one too" "old     expired  expires 2026-09-01  old-2025" "$OUT"
has "accepted: tells how to remove an old secret by hand" "az ad app credential delete --id $CLIENT --key-id" "$OUT"
check "accepted: the script itself never deletes a secret" "0" "$(az_calls 'credential delete')"
check "accepted: no consent granted as a side effect" "0" "$(az_calls 'admin-consent')"
assert_no_leak "accepted"

new_case rotate-yes
run --rotate-secret --yes
check "--yes: exit 0" "0" "$RC"
has "--yes: does not ask" "--yes given; proceeding" "$OUT"
check "--yes: one PUT" "1" "$(cf_puts)"
assert_no_leak "--yes"

new_case rotate-rerun
run --rotate-secret --yes
run --rotate-secret --yes
check "re-run: still succeeds" "0" "$RC"
check "re-run: two secrets created in total, no more" "2" "$(jq '[.[] | select(.keyId == "new-key")] | length' "$FIX/az_creds.json")"
check "re-run: the 2 original secrets and both new ones are all still there" "4" "$(jq 'length' "$FIX/az_creds.json")"
check "re-run: nothing deleted" "0" "$(az_calls 'credential delete')"
has "re-run: the second run saw the first run's secret" "keeps the 3 existing secret(s)" "$OUT"

new_case rotate-years
run --rotate-secret --yes --secret-years 1
has "--secret-years is passed through" "--years 1" "$(grep 'credential reset' "$STUB_LOG/az.log")"

new_case rotate-put-fails
touch "$FIX/cf_put_fails"
run --rotate-secret --yes
check "Cloudflare rejects the update: exit 1" "1" "$RC"
has "Cloudflare rejects: shows the API error" "Authentication error" "$OUT"
has "Cloudflare rejects: says the new secret is orphaned and safe to delete" "safe to delete" "$OUT"
has "Cloudflare rejects: says the value was not kept" "value was not stored anywhere" "$OUT"
assert_no_leak "put fails"

new_case rotate-az-fails
touch "$FIX/az_reset_fails"
run --rotate-secret --yes
check "az cannot create the secret: exit 1" "1" "$RC"
check "az fails: Cloudflare untouched" "0" "$(cf_puts)"
has "az fails: says nothing changed in Cloudflare" "nothing changed in Cloudflare" "$OUT"
has "az fails: shows az's reason" "Insufficient privileges" "$OUT"

new_case rotate-scim
edit cf_idp.json '.result.scim_config.enabled = true'
run --rotate-secret --yes
check "SCIM enabled: refuses, exit 1" "1" "$RC"
has "SCIM enabled: says why" "SCIM is enabled" "$OUT"
check "SCIM enabled: no secret was created first" "0" "$(az_calls 'credential reset')"
check "SCIM enabled: Cloudflare untouched" "0" "$(cf_puts)"

new_case rotate-tenant-mismatch
edit az_account.json '.tenantId = "77777777-7777-7777-7777-777777777777"'
run --rotate-secret --yes
check "tenant mismatch: refuses, exit 1" "1" "$RC"
check "tenant mismatch: no secret created" "0" "$(az_calls 'credential reset')"
check "tenant mismatch: Cloudflare untouched" "0" "$(cf_puts)"

new_case rotate-app-not-found
rm "$FIX/az_app.json"
run --rotate-secret --yes
check "app not found: refuses, exit 1" "1" "$RC"
check "app not found: no secret created" "0" "$(az_calls 'credential reset')"

new_case rotate-token-checked
run --rotate-secret --yes
check "rotation requests all carried the token" "0" "$(grep -c 'auth=bad' "$STUB_LOG/requests.log")"

# ---- fix: admin consent ----------------------------------------------------

echo "== fix: --grant-admin-consent"

new_case consent-needed
edit az_grants.json '.[0].scope = "User.Read openid profile email offline_access"'
jq -n --arg g "$GRAPH_SP" '[{consentType:"AllPrincipals", resourceId:$g,
  scope:"User.Read openid profile email offline_access GroupMember.Read.All Directory.Read.All"}]' >"$FIX/az_grants_after.json"
run --grant-admin-consent
check "no confirmation: exit 0" "0" "$RC"
has "shows the command" "az ad app permission admin-consent --id $CLIENT" "$OUT"
has "lists what is not consented" "Microsoft Graph Scope: GroupMember.Read.All" "$OUT"
check "unconfirmed: nothing granted" "0" "$(az_calls 'admin-consent')"
STDIN_TEXT="y" run --grant-admin-consent
check "confirmed: exit 0" "0" "$RC"
check "confirmed: consent granted once" "1" "$(az_calls 'admin-consent')"
has "confirmed: reports success" "admin consent granted" "$OUT"
check "confirmed: no secret touched" "0" "$(az_calls 'credential reset')"
check "confirmed: Cloudflare untouched" "0" "$(cf_puts)"

new_case consent-dry-run
edit az_grants.json '.[0].scope = "User.Read openid profile email offline_access"'
run --grant-admin-consent --dry-run --yes
has "dry run: says so" "Dry run: no changes made." "$OUT"
check "dry run: nothing granted" "0" "$(az_calls 'admin-consent')"

new_case consent-yes
edit az_grants.json '.[0].scope = "User.Read"'
run --grant-admin-consent --yes
check "--yes: consent granted" "1" "$(az_calls 'admin-consent')"

new_case consent-already
run --grant-admin-consent --yes
check "already consented: exit 0" "0" "$RC"
has "already consented: nothing to do" "already admin-consented; nothing to do" "$OUT"
check "already consented: az not asked to consent again" "0" "$(az_calls 'admin-consent')"

new_case consent-not-requested
edit az_app.json '.requiredResourceAccess[0].resourceAccess |= map(select(.id != "e1fe6dd8-ba31-4d61-89e7-88639da4683d"))'
run --grant-admin-consent --yes
check "permission not requested: exit 1" "1" "$RC"
check "permission not requested: consent not attempted" "0" "$(az_calls 'admin-consent')"
has "permission not requested: explains" "not requested on the app; consent cannot be granted" "$OUT"

new_case consent-denied
edit az_grants.json '.[0].scope = "User.Read"'
touch "$FIX/az_consent_fails"
run --grant-admin-consent --yes
check "consent denied: exit 1" "1" "$RC"
has "consent denied: names the role needed" "Global Administrator" "$OUT"

new_case consent-no-sp
rm "$FIX/az_sp.json"
run --grant-admin-consent --yes
check "no service principal: exit 1" "1" "$RC"
check "no service principal: consent not attempted" "0" "$(az_calls 'admin-consent')"

new_case both-fixes
edit az_grants.json '.[0].scope = "User.Read openid profile email offline_access"'
run --grant-admin-consent --rotate-secret --yes
check "both fixes: exit 0" "0" "$RC"
check "both fixes: consent granted" "1" "$(az_calls 'admin-consent')"
check "both fixes: secret rotated" "1" "$(az_calls 'credential reset')"
check "both fixes: one PUT" "1" "$(cf_puts)"
check "both fixes: consent ran before rotation" "1" "$(printf '%s\n' "$OUT" | awk '/Fix: grant admin consent/{a=NR} /Fix: rotate client secret/{b=NR} END{print (a && b && a < b) ? 1 : 0}')"
assert_no_leak "both fixes"

echo
echo "$passes passed, $failures failed"
[ "$failures" -eq 0 ]
