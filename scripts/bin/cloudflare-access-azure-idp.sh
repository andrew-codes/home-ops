#!/usr/bin/env bash
#
# Diagnose and fix a broken Cloudflare Access <-> Microsoft Entra ID (Azure AD)
# login. Written for HO-254: Access login got as far as Microsoft sign-in, then
# failed with "Failed to fetch user/group information from the identity
# provider". That is Cloudflare's call to Microsoft Graph failing after a
# successful sign-in, which almost always means the Entra app registration's
# client secret expired, was rotated or deleted, or the Graph permissions lost
# their admin consent.
#
# DEFAULT MODE IS READ-ONLY. It finds the Access Azure AD identity provider in
# Cloudflare, finds the Entra app registration behind its client id, and
# reports: client secret expiry, Graph permissions and admin consent, whether
# client id / tenant / groups setting agree on both sides, and a verdict.
#
# Fixes only happen behind their own flag. Each shows exactly what it will do
# and asks for confirmation unless --yes is given:
#   --rotate-secret         create a NEW client secret on the app (appended; the
#                           old ones are never touched) and push it to the
#                           Cloudflare identity provider
#   --grant-admin-consent   grant tenant-wide admin consent for the app's
#                           requested permissions
#
# Nothing is ever deleted. Old secrets are listed with their expiry so they can
# be removed by hand once login works. Runbook:
# https://docs.home.smith-simms.family/wiki/spaces/HA/pages/261816321
#
# Usage:
#   CLOUDFLARE_API_TOKEN=... scripts/bin/cloudflare-access-azure-idp.sh [options]
#
# Options (each can also come from the environment variable in brackets):
#   --account-id ID          Cloudflare account id [CLOUDFLARE_ACCOUNT_ID]
#                            (discovered when the token can list exactly one account)
#   --idp ID_OR_NAME         Access identity provider id or name [CLOUDFLARE_ACCESS_IDP]
#                            (discovered when the account has exactly one azureAD provider)
#   --app-id CLIENT_ID       Entra application (client) id [AZURE_APP_ID]
#                            (discovered from the identity provider's client_id; if given
#                            and different, that mismatch is reported)
#   --rotate-secret          fix: new client secret -> Cloudflare (see above)
#   --grant-admin-consent    fix: admin-consent the app's permissions
#   --yes, -y                do not ask before applying a fix
#   --dry-run                show what a fix would do, never apply it (beats --yes)
#   --secret-years N         lifetime of a newly created secret (default 2)
#   --warn-days N            flag secrets expiring within N days (default 30)
#   --recent-days N          mention secrets created within N days (default 14)
#   -h, --help               this text
#
# Environment:
#   CLOUDFLARE_API_TOKEN     required. API token; never passed on a command line.
#
# Requires: az (signed in: `az login`), curl, jq.
#
# Cloudflare token permissions (Account scope):
#   diagnose        Access: Organizations, Identity Providers, and Groups  Read
#   --rotate-secret Access: Organizations, Identity Providers, and Groups  Edit
#   account discovery additionally needs Account Settings Read; skip it by
#   passing --account-id.
#
# Azure roles, for the signed-in `az` user:
#   diagnose             any directory member who can read the app registration
#                        (owner of the app or Application/Cloud Application Administrator
#                        to read secret metadata and consent grants)
#   --rotate-secret      owner of the app, or Application Administrator /
#                        Cloud Application Administrator
#   --grant-admin-consent Global Administrator or Privileged Role Administrator
#
# Secret handling: the new client secret goes from `az` output straight into
# the Cloudflare API call in this process's memory. It is never printed,
# logged, written to disk, or put on a command line (so it is not visible in
# `ps`). The Cloudflare API token is likewise fed to curl through a
# descriptor, not an argument. The script refuses to run under `set -x`.
#
# Exit codes: 0 nothing definite wrong (or fix applied), 1 usage or tooling error
# or a failed fix, 2 read-only diagnosis found a definite problem.
#
# Docs this was written against:
#   https://developers.cloudflare.com/cloudflare-one/integrations/identity-providers/azuread/
#   https://developers.cloudflare.com/api/resources/zero_trust/subresources/identity_providers/
#   https://learn.microsoft.com/en-us/cli/azure/ad/app/credential
#   https://learn.microsoft.com/en-us/cli/azure/ad/app/permission

set -uo pipefail

case $- in
  *x*)
    echo "error: refusing to run with xtrace (set -x) enabled; it would print the new client secret" >&2
    exit 1
    ;;
esac

CF_API="https://api.cloudflare.com/client/v4"
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"

ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
IDP_SELECTOR="${CLOUDFLARE_ACCESS_IDP:-}"
APP_ID="${AZURE_APP_ID:-}"
DO_ROTATE=0
DO_CONSENT=0
ASSUME_YES=0
DRY_RUN=0
SECRET_YEARS=2
WARN_DAYS=30
RECENT_DAYS=14

say() { printf '%s\n' "$*"; }
note() { printf '       %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
bad() { printf '[FAIL] %s\n' "$*"; }
heading() { printf '\n== %s ==\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  # The header comment above is the documentation; print its usage block.
  sed -n '2,/^set -uo pipefail/p' "$0" | sed -e '/^set -uo pipefail/d' -e 's/^# \{0,1\}//' -e 's/^#$//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --account-id) ACCOUNT_ID="${2:-}"; shift 2 ;;
    --idp) IDP_SELECTOR="${2:-}"; shift 2 ;;
    --app-id) APP_ID="${2:-}"; shift 2 ;;
    --rotate-secret) DO_ROTATE=1; shift ;;
    --grant-admin-consent) DO_CONSENT=1; shift ;;
    --yes | -y) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --secret-years) SECRET_YEARS="${2:-}"; shift 2 ;;
    --warn-days) WARN_DAYS="${2:-}"; shift 2 ;;
    --recent-days) RECENT_DAYS="${2:-}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

for n in SECRET_YEARS WARN_DAYS RECENT_DAYS; do
  case "${!n}" in
    '' | *[!0-9]*) die "$n must be a whole number" ;;
  esac
done
[ "$SECRET_YEARS" -ge 1 ] || die "--secret-years must be at least 1"

# ---- prerequisites ---------------------------------------------------------

for tool in az curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found on PATH: $tool"
done
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || die "CLOUDFLARE_API_TOKEN is not set (see --help for the token permissions)"
# The token is handed to curl in a config file, so keep it to the characters
# Cloudflare tokens use. This also rules out quote injection into that config.
case "$CLOUDFLARE_API_TOKEN" in
  *[!A-Za-z0-9_-]*) die "CLOUDFLARE_API_TOKEN contains unexpected characters; expected a Cloudflare API token" ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
NOW="${CFAZ_NOW_EPOCH:-$(date +%s)}"

# ---- helpers ---------------------------------------------------------------

# az_to FILE ARGS...: run az, stdout (JSON) to FILE, stderr to $WORK/az.err.
# Only for read-only calls and `admin-consent`; secrets never go through here.
az_to() {
  local out="$1"
  shift
  az "$@" --only-show-errors -o json >"$out" 2>"$WORK/az.err"
}

az_err() { head -n 3 "$WORK/az.err" | sed 's/^/       az: /'; }

# cf_api METHOD PATH: prints the response body. A PUT takes its JSON body on
# stdin. The API token reaches curl through a process-substitution config
# (printf is a builtin, so nothing appears in an argument list) and the body
# through stdin.
cf_api() {
  local method="$1" path="$2" body resp status payload
  if [ "$method" = PUT ]; then
    body="$(cat)"
    if [ -z "$body" ]; then
      echo "cloudflare: refusing to send an empty request body" >&2
      return 1
    fi
    resp="$(printf '%s' "$body" | curl -sS -X PUT \
      -K <(printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN") \
      -H 'Content-Type: application/json' --data-binary @- \
      -w '\n%{http_code}' "$CF_API$path")" || {
      echo "cloudflare: request failed (network or TLS error)" >&2
      return 1
    }
  else
    resp="$(curl -sS -X GET \
      -K <(printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN") \
      -w '\n%{http_code}' "$CF_API$path" </dev/null)" || {
      echo "cloudflare: request failed (network or TLS error)" >&2
      return 1
    }
  fi
  status="${resp##*$'\n'}"
  payload="${resp%$'\n'*}"
  if [ "${status:0:1}" != 2 ] || [ "$(printf '%s' "$payload" | jq -r '.success // false' 2>/dev/null)" != true ]; then
    echo "cloudflare: $method $path failed with HTTP $status" >&2
    printf '%s' "$payload" | jq -r '.errors[]? | "  cloudflare error \(.code): \(.message)"' >&2 2>/dev/null
    case "$status" in
      401 | 403) echo "  the token needs the Access identity provider permissions listed in --help" >&2 ;;
    esac
    return 1
  fi
  printf '%s' "$payload"
}

confirm() {
  if [ "$ASSUME_YES" = 1 ]; then
    say "  --yes given; proceeding without asking."
    return 0
  fi
  local answer=''
  printf '  Proceed? [y/N] '
  read -r answer || true # EOF with no input leaves it empty, i.e. no
  case "$answer" in
    y | Y | yes | YES) return 0 ;;
  esac
  say "  Not confirmed. Nothing changed."
  return 1
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---- Cloudflare: account and identity provider -----------------------------

heading "Cloudflare Access"

if [ -z "$ACCOUNT_ID" ]; then
  cf_api GET "/accounts?per_page=50" >"$WORK/accounts.json" ||
    die "could not list Cloudflare accounts; pass --account-id (or set CLOUDFLARE_ACCOUNT_ID)"
  case "$(jq '.result | length' "$WORK/accounts.json")" in
    0) die "the token can see no Cloudflare accounts; pass --account-id" ;;
    1) ACCOUNT_ID="$(jq -r '.result[0].id' "$WORK/accounts.json")" ;;
    *)
      jq -r '.result[] | "  \(.id)  \(.name)"' "$WORK/accounts.json" >&2
      die "the token can see several accounts (listed above); pass --account-id"
      ;;
  esac
fi

cf_api GET "/accounts/$ACCOUNT_ID/access/identity_providers?per_page=100" >"$WORK/idps.json" ||
  die "could not list Access identity providers"
jq '[.result[] | select(.type == "azureAD")]' "$WORK/idps.json" >"$WORK/azure-idps.json"
if [ -n "$IDP_SELECTOR" ]; then
  jq --arg s "$IDP_SELECTOR" '[.[] | select(.id == $s or .name == $s)]' "$WORK/azure-idps.json" >"$WORK/azure-idps.sel.json"
  mv "$WORK/azure-idps.sel.json" "$WORK/azure-idps.json"
fi
case "$(jq 'length' "$WORK/azure-idps.json")" in
  0)
    jq -r '.result[] | "  \(.id)  \(.type)  \(.name)"' "$WORK/idps.json" >&2
    die "no azureAD identity provider${IDP_SELECTOR:+ matching \"$IDP_SELECTOR\"} in this account (providers listed above)"
    ;;
  1) IDP_ID="$(jq -r '.[0].id' "$WORK/azure-idps.json")" ;;
  *)
    jq -r '.[] | "  \(.id)  \(.name)"' "$WORK/azure-idps.json" >&2
    die "several azureAD identity providers (listed above); pass --idp with the id or name"
    ;;
esac

IDP_PATH="/accounts/$ACCOUNT_ID/access/identity_providers/$IDP_ID"
cf_api GET "$IDP_PATH" >"$WORK/idp.json" || die "could not read the identity provider"

IDP_NAME="$(jq -r '.result.name' "$WORK/idp.json")"
CF_CLIENT_ID="$(jq -r '.result.config.client_id // ""' "$WORK/idp.json")"
CF_DIRECTORY_ID="$(jq -r '.result.config.directory_id // ""' "$WORK/idp.json")"
CF_SUPPORT_GROUPS="$(jq -r '.result.config.support_groups // false' "$WORK/idp.json")"
CF_SCIM_ENABLED="$(jq -r '.result.scim_config.enabled // false' "$WORK/idp.json")"

TEAM_DOMAIN=''
if cf_api GET "/accounts/$ACCOUNT_ID/access/organizations" >"$WORK/org.json" 2>/dev/null; then
  TEAM_DOMAIN="$(jq -r '.result.auth_domain // ""' "$WORK/org.json")"
fi

say "Identity provider: $IDP_NAME ($IDP_ID)"
[ -z "$TEAM_DOMAIN" ] || say "Team domain:       $TEAM_DOMAIN"
say "Client id:         ${CF_CLIENT_ID:-<not set>}"
say "Directory id:      ${CF_DIRECTORY_ID:-<not set>}"
say "Groups support:    $CF_SUPPORT_GROUPS"

# ---- Azure: session, app registration, service principal -------------------

heading "Microsoft Entra ID"

az_to "$WORK/account.json" account show || {
  az_err
  die "az is not signed in; run 'az login' (as a user who can manage the app registration)"
}
AZ_TENANT="$(jq -r '.tenantId' "$WORK/account.json")"
AZ_USER="$(jq -r '.user.name // "unknown"' "$WORK/account.json")"
say "az session:        $AZ_USER, tenant $AZ_TENANT"

# Findings. Each verdict flag is set once by the check that owns it.
F_CLIENT_ID_MISMATCH=0
F_TENANT_MISMATCH=0
F_APP_NOT_FOUND=0
F_NO_SP=0
F_NO_VALID_SECRET=0
F_PERMISSIONS=0
F_EXPIRING=0
APP_FOUND=0
SP_FOUND=0
PERM_FIX_CONSENT=0 # something is requested on the app but not admin-consented
PERM_FIX_ADD=0     # something required is not even requested on the app
RECENT_SECRET=0
EXPIRED_COUNT=0
VALID_COUNT=0

if [ -z "$APP_ID" ]; then
  APP_ID="$CF_CLIENT_ID"
elif [ -n "$CF_CLIENT_ID" ] && [ "$(lower "$APP_ID")" != "$(lower "$CF_CLIENT_ID")" ]; then
  F_CLIENT_ID_MISMATCH=1
  bad "client id mismatch: Cloudflare uses $CF_CLIENT_ID but --app-id/AZURE_APP_ID is $APP_ID"
fi
[ -n "$APP_ID" ] || die "the identity provider has no client_id and no --app-id was given"

if [ -z "$CF_DIRECTORY_ID" ]; then
  F_TENANT_MISMATCH=1
  bad "Cloudflare has no directory (tenant) id set"
elif [ "$(lower "$CF_DIRECTORY_ID")" != "$(lower "$AZ_TENANT")" ]; then
  F_TENANT_MISMATCH=1
  bad "tenant mismatch: Cloudflare directory id is $CF_DIRECTORY_ID but the az session is in tenant $AZ_TENANT"
  note "sign in to the right tenant with: az login --tenant $CF_DIRECTORY_ID"
else
  pass "directory (tenant) id matches the az session's tenant"
fi

if az_to "$WORK/app.json" ad app show --id "$APP_ID"; then
  APP_FOUND=1
  say "App registration:  $(jq -r '.displayName' "$WORK/app.json") (client id $APP_ID)"
  if [ "$F_CLIENT_ID_MISMATCH" = 0 ]; then
    pass "client id in Cloudflare matches the app registration"
  fi
else
  F_APP_NOT_FOUND=1
  bad "could not read app registration $APP_ID in tenant $AZ_TENANT"
  az_err
  note "it may have been deleted, live in another tenant, or this az user cannot read it"
fi

if [ "$APP_FOUND" = 1 ]; then
  # -- client secrets --
  heading "Client secrets"
  az_to "$WORK/creds.json" ad app credential list --id "$APP_ID" || {
    az_err
    die "could not list the app's client secrets"
  }
  jq --argjson now "$NOW" --argjson warn "$WARN_DAYS" --argjson recent "$RECENT_DAYS" '
    def ts: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
    map(
      (.endDateTime // .endDate) as $e | (.startDateTime // .startDate) as $s |
      { keyId: .keyId, name: (.displayName // ""), hint: (.hint // ""),
        end: ($e | ts), start: (if $s == null then null else ($s | ts) end) }
      | .days = (((.end - $now) / 86400) | floor)
      | .state = (if .end <= $now then "expired"
                  elif (.end - $now) < ($warn * 86400) then "expiring"
                  else "valid" end)
      | .recent = (.start != null and .start >= ($now - $recent * 86400)))
    | sort_by(.end)' "$WORK/creds.json" >"$WORK/secrets.json" ||
    die "could not parse the client secret list from az"

  SECRET_TOTAL="$(jq 'length' "$WORK/secrets.json")"
  EXPIRED_COUNT="$(jq '[.[] | select(.state == "expired")] | length' "$WORK/secrets.json")"
  VALID_COUNT="$(jq '[.[] | select(.state != "expired")] | length' "$WORK/secrets.json")"
  RECENT_SECRET="$(jq '[.[] | select(.recent)] | length' "$WORK/secrets.json")"

  if [ "$SECRET_TOTAL" = 0 ]; then
    say "  (no client secrets on this app)"
  else
    jq -r '.[] | "  \(.state | . + " " * (9 - length))  expires \(.end | strftime("%Y-%m-%d"))  (\(.days)d)  \(if .name == "" then "(unnamed)" else .name end)  key \(.keyId)"' "$WORK/secrets.json"
  fi

  if [ "$VALID_COUNT" = 0 ]; then
    F_NO_VALID_SECRET=1
    bad "no unexpired client secret on the app ($EXPIRED_COUNT expired)"
  elif [ "$(jq '[.[] | select(.state == "valid")] | length' "$WORK/secrets.json")" = 0 ]; then
    F_EXPIRING=1
    warn "every unexpired secret expires within $WARN_DAYS days"
  else
    pass "at least one client secret is valid for more than $WARN_DAYS days"
  fi
  if [ "$RECENT_SECRET" != 0 ]; then
    warn "a secret was created in the last $RECENT_DAYS days; Cloudflare only works if it was given that value (not the secret id)"
  fi
  note "Cloudflare never reveals the secret it holds, so which of these it is using cannot be checked."

  # -- service principal --
  heading "Graph permissions and admin consent"
  if az_to "$WORK/sp.json" ad sp show --id "$APP_ID"; then
    SP_FOUND=1
    SP_OBJECT_ID="$(jq -r '.id' "$WORK/sp.json")"
    if [ "$(jq -r 'if .accountEnabled == false then "false" else "true" end' "$WORK/sp.json")" = false ]; then
      F_NO_SP=1
      bad "the enterprise application (service principal) is disabled for sign-in"
    fi
  else
    F_NO_SP=1
    bad "the app has no enterprise application (service principal) in tenant $AZ_TENANT, so nothing can be consented"
    note "create it with: az ad sp create --id $APP_ID"
  fi

  if [ "$SP_FOUND" = 1 ]; then
    az_to "$WORK/graph.json" ad sp show --id "$GRAPH_APP_ID" || {
      az_err
      die "could not read the Microsoft Graph service principal"
    }
    az_to "$WORK/grants.json" ad app permission list-grants --id "$APP_ID" || {
      az_err
      die "could not list the app's permission grants"
    }
    echo '{"value":[]}' >"$WORK/roles.json"
    if jq -e '[.requiredResourceAccess[]? | select(.resourceAppId == "'"$GRAPH_APP_ID"'") | .resourceAccess[]? | select(.type == "Role")] | length > 0' "$WORK/app.json" >/dev/null; then
      az_to "$WORK/roles.json" rest --method GET \
        --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_OBJECT_ID/appRoleAssignments" || {
        az_err
        die "could not list the app's application-permission consents"
      }
    fi

    jq -n --arg graphApp "$GRAPH_APP_ID" \
      --slurpfile app "$WORK/app.json" --slurpfile graph "$WORK/graph.json" \
      --slurpfile grants "$WORK/grants.json" --slurpfile roles "$WORK/roles.json" '
      $graph[0] as $g
      | [ $grants[0][]? | select(.consentType == "AllPrincipals" and .resourceId == $g.id)
          | .scope | split(" ")[] | select(length > 0) ] as $grantedScopes
      | [ $roles[0].value[]? | select(.resourceId == $g.id) | .appRoleId ] as $grantedRoles
      | [ $app[0].requiredResourceAccess[]? | select(.resourceAppId == $graphApp)
          | .resourceAccess[]? | . as $ra
          | { type: $ra.type, id: $ra.id,
              name: (first(if $ra.type == "Scope"
                           then ($g.oauth2PermissionScopes[]? | select(.id == $ra.id) | .value)
                           else ($g.appRoles[]? | select(.id == $ra.id) | .value) end)
                     // ("unknown:" + $ra.id)) }
          | .consented = (if .type == "Scope" then (.name as $n | $grantedScopes | index($n) != null)
                          else (.id as $i | $grantedRoles | index($i) != null) end) ]' >"$WORK/perms.json" ||
      die "could not evaluate the app's Graph permissions"

    perm_state() {
      jq -r --arg n "$1" '[.[] | select(.name == $n)]
        | if length == 0 then "missing" elif any(.consented) then "consented" else "unconsented" end' "$WORK/perms.json"
    }

    # required = Cloudflare fails without it; documented = in Cloudflare's tested set.
    check_perm() { # name level(required|documented)
      local state
      state="$(perm_state "$1")"
      case "$state" in
        consented) pass "$1: requested and admin-consented" ;;
        unconsented)
          PERM_FIX_CONSENT=1
          if [ "$2" = required ]; then
            F_PERMISSIONS=1
            bad "$1: requested but NOT admin-consented"
          else
            warn "$1: requested but not admin-consented"
          fi
          ;;
        missing)
          if [ "$2" = required ]; then
            F_PERMISSIONS=1
            PERM_FIX_ADD=1
            bad "$1: not requested on the app"
          else
            warn "$1: not requested on the app (part of Cloudflare's documented set)"
          fi
          ;;
      esac
    }

    check_perm User.Read required
    for p in openid profile email offline_access; do
      check_perm "$p" documented
    done

    if [ "$CF_SUPPORT_GROUPS" = true ]; then
      gm="$(perm_state GroupMember.Read.All)"
      dr="$(perm_state Directory.Read.All)"
      if [ "$gm" = consented ] || [ "$dr" = consented ]; then
        pass "groups are enabled in Cloudflare and a group-read permission is admin-consented"
      else
        F_PERMISSIONS=1
        bad "groups are enabled in Cloudflare but neither GroupMember.Read.All nor Directory.Read.All is admin-consented"
        if [ "$gm" = missing ] && [ "$dr" = missing ]; then PERM_FIX_ADD=1; else PERM_FIX_CONSENT=1; fi
      fi
      check_perm GroupMember.Read.All documented
      check_perm Directory.Read.All documented
    else
      if [ "$(perm_state GroupMember.Read.All)" != missing ] || [ "$(perm_state Directory.Read.All)" != missing ]; then
        note "the app requests group permissions but Groups support is off in Cloudflare; harmless, but groups will not be available to Access policies"
      fi
    fi
  fi
fi

# ---- verdict ---------------------------------------------------------------

heading "Verdict"

VERDICT=''
PROBLEMS=0
verdict_line() { # code, explanation
  PROBLEMS=1
  if [ -z "$VERDICT" ]; then
    VERDICT="$1"
    say "VERDICT: $1"
    say "  $2"
  else
    say "ALSO:    $1"
    say "  $2"
  fi
}

[ "$F_APP_NOT_FOUND" = 0 ] || verdict_line APP_NOT_FOUND \
  "Cloudflare's client id cannot be found as an app registration in the az session's tenant. Sign in to the correct tenant, or the app was deleted and Cloudflare needs a new app's client id and secret (not fixable by this script)."
[ "$F_TENANT_MISMATCH" = 0 ] || verdict_line TENANT_MISMATCH \
  "Cloudflare's directory (tenant) id does not match the tenant the app lives in. Correct it in Cloudflare Zero Trust > Settings > Authentication (not fixable by this script)."
[ "$F_CLIENT_ID_MISMATCH" = 0 ] || verdict_line CLIENT_ID_MISMATCH \
  "Cloudflare is configured with a different client id than the app you pointed at. Update the client id in Cloudflare Zero Trust > Settings > Authentication (not fixable by this script)."
[ "$F_NO_VALID_SECRET" = 0 ] || verdict_line EXPIRED_SECRET \
  "Every client secret on the app has expired, so Microsoft rejects Cloudflare's token requests. This is the classic cause of this error. Fix: --rotate-secret."
[ "$F_NO_SP" = 0 ] || verdict_line NO_SERVICE_PRINCIPAL \
  "The app has no usable enterprise application in the tenant, so user sign-in and consent cannot work. Fix: az ad sp create --id $APP_ID (or enable it for sign-in in Entra > Enterprise applications)."
if [ "$F_PERMISSIONS" != 0 ]; then
  if [ "$PERM_FIX_ADD" = 1 ]; then
    verdict_line PERMISSIONS \
      "A Graph permission Cloudflare needs is not even requested on the app. Add it (Entra > App registrations > API permissions > Microsoft Graph > Delegated: User.Read, and GroupMember.Read.All / Directory.Read.All for groups), then run --grant-admin-consent."
  else
    verdict_line PERMISSIONS \
      "A Graph permission Cloudflare needs is requested but lost its admin consent. Fix: --grant-admin-consent."
  fi
fi
if [ "$PROBLEMS" = 0 ]; then
  VERDICT=STALE_SECRET_SUSPECTED
  say "VERDICT: STALE_SECRET_SUSPECTED"
  say "  Nothing is wrong on the Azure side: the app exists, the tenant and client id agree, there is an unexpired secret and the permissions are consented."
  say "  Cloudflare's stored secret cannot be read back, so the most likely remaining cause is that it is not any current secret (rotated, deleted, expired, or the secret id was pasted instead of the value)."
  if [ "$EXPIRED_COUNT" != 0 ]; then
    say "  $EXPIRED_COUNT expired secret(s) exist; if Cloudflare still holds one of those, that is the cause."
  fi
  if [ "$RECENT_SECRET" != 0 ]; then
    say "  A secret was created in the last $RECENT_DAYS days, which fits a rotation Cloudflare was never told about."
  fi
  say "  Fix: --rotate-secret (appends a new secret; old ones are kept). If it still fails after that, look at Conditional Access policies and"
  say "  'User assignment required' on the enterprise application, which reject sign-ins Cloudflare makes on behalf of users."
  PROBLEMS=0
elif [ "$F_EXPIRING" = 1 ]; then
  say "NOTE:    every unexpired secret expires within $WARN_DAYS days; rotate before then."
fi

# ---- fixes -----------------------------------------------------------------

FIX_FAILED=0

list_secrets() {
  az_to "$WORK/creds.json" ad app credential list --id "$APP_ID" || {
    az_err
    return 1
  }
  jq -r --argjson now "$NOW" --arg newName "${1:-}" '
    def ts: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
    sort_by((.endDateTime // .endDate) | ts)[]
    | (.endDateTime // .endDate | ts) as $e
    | "  \(if .displayName == $newName and $newName != "" then "NEW    " else "old    " end) \(if $e <= $now then "expired" else "valid  " end)  expires \($e | strftime("%Y-%m-%d"))  \(.displayName // "(unnamed)")  key \(.keyId)"' "$WORK/creds.json"
}

fix_grant_consent() {
  heading "Fix: grant admin consent"
  if [ "$APP_FOUND" = 0 ] || [ "$SP_FOUND" = 0 ]; then
    bad "cannot grant consent: the app registration or its enterprise application was not found (see above)"
    FIX_FAILED=1
    return
  fi
  if [ "$PERM_FIX_CONSENT" = 0 ]; then
    if [ "$PERM_FIX_ADD" = 1 ]; then
      bad "a required permission is not requested on the app; consent cannot be granted for it (see the PERMISSIONS verdict)"
      FIX_FAILED=1
    else
      pass "every requested Graph permission is already admin-consented; nothing to do"
    fi
    return
  fi
  say "Will run, as $AZ_USER in tenant $AZ_TENANT:"
  say "  az ad app permission admin-consent --id $APP_ID"
  say "This grants tenant-wide admin consent for ALL permissions requested on the app. Not yet consented:"
  jq -r '.[] | select(.consented | not) | "  Microsoft Graph \(.type): \(.name)"' "$WORK/perms.json"
  jq -r --arg g "$GRAPH_APP_ID" '[.requiredResourceAccess[]? | select(.resourceAppId != $g) | .resourceAccess[]?] | length as $n | if $n > 0 then "  (+ \($n) permission(s) on other APIs, which this also consents)" else empty end' "$WORK/app.json"
  if [ "$DRY_RUN" = 1 ]; then
    say "Dry run: no changes made."
    return
  fi
  confirm || return
  if az_to "$WORK/consent.json" ad app permission admin-consent --id "$APP_ID"; then
    pass "admin consent granted"
    note "Entra can take a minute or two to propagate; retry Access login after that."
  else
    bad "admin-consent failed (this needs Global Administrator or Privileged Role Administrator)"
    az_err
    FIX_FAILED=1
  fi
}

fix_rotate_secret() {
  heading "Fix: rotate client secret"
  if [ "$APP_FOUND" = 0 ] || [ "$F_TENANT_MISMATCH" = 1 ] || [ "$F_CLIENT_ID_MISMATCH" = 1 ]; then
    bad "refusing to rotate: the app cannot be found, or Cloudflare points at a different tenant/client id (see the verdict above)"
    FIX_FAILED=1
    return
  fi
  if [ "$CF_SCIM_ENABLED" = true ]; then
    bad "refusing to rotate: SCIM is enabled on this identity provider and the update API replaces the whole object"
    note "paste the new secret in Cloudflare Zero Trust > Settings > Authentication instead (create one with: az ad app credential reset --id $APP_ID --append)"
    FIX_FAILED=1
    return
  fi
  local new_name existing_count
  new_name="cloudflare-access-$(date -u -r "$NOW" +%Y%m%d-%H%M%S 2>/dev/null || date -u -d "@$NOW" +%Y%m%d-%H%M%S)"
  existing_count="$(jq 'length' "$WORK/secrets.json")"
  say "Will do, as $AZ_USER:"
  say "  1. az ad app credential reset --id $APP_ID --append --display-name $new_name --years $SECRET_YEARS"
  say "     (--append keeps the $existing_count existing secret(s); nothing is deleted or changed)"
  say "  2. PUT $CF_API$IDP_PATH"
  say "     to identity provider \"$IDP_NAME\", replacing only config.client_secret. Kept as they are now:"
  say "     client_id, directory_id, support_groups ($CF_SUPPORT_GROUPS), email_claim_name, claims, prompt, conditional_access_enabled, name, type"
  say "The new secret value goes from az straight into that request in memory. It is never printed, logged, written to disk or passed as an argument."
  if [ "$DRY_RUN" = 1 ]; then
    say "Dry run: no changes made."
    return
  fi
  confirm || return

  # Re-read the provider right before the update so the body we send is its
  # current shape (the API replaces the whole object), and fail before any
  # secret exists if that is not possible.
  local fresh put_template put_body az_out
  fresh="$(cf_api GET "$IDP_PATH")" || {
    bad "could not re-read the identity provider; nothing changed"
    FIX_FAILED=1
    return
  }
  put_template="$(printf '%s' "$fresh" | jq -c '{name: .result.name, type: .result.type, config: (.result.config | del(.client_secret))}')" || {
    bad "could not build the update request; nothing changed"
    FIX_FAILED=1
    return
  }

  if ! az_out="$(az ad app credential reset --id "$APP_ID" --append \
    --display-name "$new_name" --years "$SECRET_YEARS" --only-show-errors -o json 2>"$WORK/az.err")"; then
    bad "could not create the new client secret; nothing changed in Cloudflare"
    az_err
    note "your tenant may cap secret lifetime (try --secret-years 1) or you may lack the Application Administrator role"
    FIX_FAILED=1
    return
  fi
  if ! put_body="$(printf '%s' "$az_out" | jq -ce --argjson tpl "$put_template" \
    'if (.password // "") == "" then error("az returned no password") else . as $r | $tpl | .config.client_secret = $r.password end' 2>/dev/null)"; then
    unset az_out
    bad "az did not return a secret; Cloudflare was not changed"
    FIX_FAILED=1
    return
  fi
  unset az_out
  if printf '%s' "$put_body" | cf_api PUT "$IDP_PATH" >/dev/null; then
    unset put_body
    pass "new client secret created in Azure and pushed to Cloudflare identity provider \"$IDP_NAME\""
    say "The new secret value was NOT printed, logged, or written anywhere."
    note "test it: open an Access-protected app and sign in with Microsoft"
  else
    unset put_body
    bad "Cloudflare rejected the update. The new secret exists in Azure ($new_name) but its value was not stored anywhere."
    note "it is unused and safe to delete; re-run --rotate-secret to try again"
    FIX_FAILED=1
  fi
  say ""
  say "Client secrets on the app now ('old' ones are kept; remove them yourself once login works):"
  list_secrets "$new_name" || true
  say "Remove an old secret after verifying login with:"
  say "  az ad app credential delete --id $APP_ID --key-id <key id above>"
}

if [ "$DO_CONSENT" = 1 ]; then fix_grant_consent; fi
if [ "$DO_ROTATE" = 1 ]; then fix_rotate_secret; fi

if [ "$DO_CONSENT" = 0 ] && [ "$DO_ROTATE" = 0 ]; then
  say ""
  say "Read-only run: nothing was changed. Fix flags: --rotate-secret, --grant-admin-consent (each shows its plan and asks first; --dry-run to only look)."
fi

if [ "$FIX_FAILED" != 0 ]; then exit 1; fi
if [ "$PROBLEMS" != 0 ] && [ "$DO_CONSENT" = 0 ] && [ "$DO_ROTATE" = 0 ]; then exit 2; fi
exit 0
