#!/usr/bin/env bash
#
# Create a GitLab Runner in GitLab and land its authentication token in SSM Parameter Store,
# without the token ever passing through Terraform.
#
# The token exists in exactly three places:
#   1. GitLab's database
#   2. this process's memory and one 0600 file inside a private tmpdir, for a few hundred ms
#   3. the SSM SecureString
#
# It is never an argv element (visible in `ps` to every user on the box), never an environment
# variable that a child process inherits, never echoed, and never returned to Terraform.
#
# Idempotent: if the parameter already exists AND the runner id recorded alongside it still
# resolves in GitLab, this is a no-op. That matters because every extra call to
# POST /user/runners mints a *new* runner that nothing will ever clean up.
#
set -euo pipefail

# Guard against a caller running us under `set -x`, or CI_DEBUG_TRACE, which would print the
# token. This is not paranoia: `CI_DEBUG_TRACE: "true"` is a one-line change any developer can
# make to a .gitlab-ci.yml.
set +x

usage() {
  cat >&2 <<'EOF'
usage: provision-runner-token.sh --scope {group|project} --id <numeric id> \
         --name <runner name> --parameter <ssm name> --kms-key-arn <arn> \
         [--tags <comma,separated>] [--region <aws region>] [--force]

environment:
  GITLAB_URL          e.g. https://gitlab.internal.example.com
  GITLAB_API_TOKEN    a token with the `create_runner` scope, nothing more
EOF
  exit 2
}

SCOPE="" ; SCOPE_ID="" ; RUNNER_NAME="" ; PARAMETER="" ; KMS_KEY_ARN=""
TAG_LIST="" ; REGION="${AWS_REGION:-eu-west-2}" ; FORCE="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --scope)       SCOPE="$2"; shift 2 ;;
    --id)          SCOPE_ID="$2"; shift 2 ;;
    --name)        RUNNER_NAME="$2"; shift 2 ;;
    --parameter)   PARAMETER="$2"; shift 2 ;;
    --kms-key-arn) KMS_KEY_ARN="$2"; shift 2 ;;
    --tags)        TAG_LIST="$2"; shift 2 ;;
    --region)      REGION="$2"; shift 2 ;;
    --force)       FORCE="true"; shift ;;
    *)             usage ;;
  esac
done

[ -n "$SCOPE" ] && [ -n "$SCOPE_ID" ] && [ -n "$RUNNER_NAME" ] || usage
[ -n "$PARAMETER" ] && [ -n "$KMS_KEY_ARN" ] || usage
: "${GITLAB_URL:?GITLAB_URL is not set}"
: "${GITLAB_API_TOKEN:?GITLAB_API_TOKEN is not set}"

case "$SCOPE" in
  group)   RUNNER_TYPE="group_type";   ID_FIELD="group_id"   ;;
  project) RUNNER_TYPE="project_type"; ID_FIELD="project_id" ;;
  *)       echo "ERROR: --scope must be group or project" >&2; exit 2 ;;
esac

# Companion parameters. Plain Strings, no secret content — they exist so that a second run,
# a `destroy`, or a human debugging at 3am can answer "which GitLab runner is this?".
ID_PARAMETER="${PARAMETER%/*}/runner-id"
EXPIRY_PARAMETER="${PARAMETER%/*}/token-expires-at"

WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

# curl reads the PRIVATE-TOKEN header from a config file rather than the command line, so the
# GitLab token is not visible in `ps` either.
umask 077
printf 'header = "PRIVATE-TOKEN: %s"\n' "$GITLAB_API_TOKEN" > "$WORKDIR/curlrc"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Idempotency check
# ---------------------------------------------------------------------------
# `describe-parameters` returns metadata only. Deliberately not `get-parameter`: we have no
# business reading the token back, and a script that can read it is a script that can leak it.
parameter_exists() {
  local count
  count="$(aws ssm describe-parameters \
    --region "$REGION" \
    --parameter-filters "Key=Name,Values=$1" \
    --query 'length(Parameters)' --output text 2>/dev/null || echo 0)"
  [ "$count" = "1" ]
}

runner_still_exists() {
  local id="$1"
  curl --silent --show-error --fail --config "$WORKDIR/curlrc" \
    --url "$GITLAB_URL/api/v4/runners/$id" --output /dev/null 2>/dev/null
}

if [ "$FORCE" != "true" ] && parameter_exists "$PARAMETER"; then
  EXISTING_ID="$(aws ssm get-parameter --region "$REGION" --name "$ID_PARAMETER" \
    --query 'Parameter.Value' --output text 2>/dev/null || echo "")"

  if [ -n "$EXISTING_ID" ] && runner_still_exists "$EXISTING_ID"; then
    log "runner $EXISTING_ID already provisioned and $PARAMETER exists; nothing to do"
    exit 0
  fi

  log "WARN: $PARAMETER exists but runner id '${EXISTING_ID:-unknown}' does not resolve in GitLab."
  log "WARN: the instance is holding a token GitLab no longer honours. Re-provisioning."
fi

# ---------------------------------------------------------------------------
# 2. Create the runner in GitLab
# ---------------------------------------------------------------------------
# POST /user/runners returns the token exactly once. There is no API to read it back, which is
# precisely why the write to SSM below must not be allowed to fail silently.
log "creating $RUNNER_TYPE runner '$RUNNER_NAME' under $ID_FIELD=$SCOPE_ID"

HTTP_STATUS="$(curl --silent --show-error --config "$WORKDIR/curlrc" \
  --request POST \
  --url "$GITLAB_URL/api/v4/user/runners" \
  --data-urlencode "runner_type=$RUNNER_TYPE" \
  --data-urlencode "$ID_FIELD=$SCOPE_ID" \
  --data-urlencode "description=$RUNNER_NAME (managed by platform bootstrap)" \
  --data-urlencode "tag_list=$TAG_LIST" \
  --data-urlencode "run_untagged=false" \
  --data-urlencode "locked=true" \
  --data-urlencode "access_level=not_protected" \
  --output "$WORKDIR/response.json" \
  --write-out '%{http_code}')"

if [ "$HTTP_STATUS" != "201" ]; then
  # The body of a GitLab error never contains the token — a failed create did not mint one.
  log "ERROR: GitLab returned HTTP $HTTP_STATUS"
  sed -e 's/glrt-[A-Za-z0-9_-]*/glrt-REDACTED/g' "$WORKDIR/response.json" >&2 || true
  exit 1
fi

jq -r '.token' "$WORKDIR/response.json" | tr -d '\n' > "$WORKDIR/token"
RUNNER_ID="$(jq -r '.id' "$WORKDIR/response.json")"
TOKEN_EXPIRES_AT="$(jq -r '.token_expires_at // "never"' "$WORKDIR/response.json")"

if [ ! -s "$WORKDIR/token" ] || ! grep -q '^glrt-' "$WORKDIR/token"; then
  log "ERROR: GitLab returned 201 but no usable glrt- token. Runner $RUNNER_ID is now orphaned."
  log "ERROR: delete it with: DELETE $GITLAB_URL/api/v4/runners/$RUNNER_ID"
  exit 1
fi

log "created runner id=$RUNNER_ID token_expires_at=$TOKEN_EXPIRES_AT"

if [ "$TOKEN_EXPIRES_AT" != "never" ] && [ "$TOKEN_EXPIRES_AT" != "null" ]; then
  log "WARN: this GitLab instance enforces runner token expiry."
  log "WARN: the agent rotates its own token into config.toml on the running host, but SSM is"
  log "WARN: not updated. The next instance replacement will boot with a token GitLab has"
  log "WARN: already rotated away from. See docs/token-provisioning.md."
fi

# ---------------------------------------------------------------------------
# 3. Write it to SSM
# ---------------------------------------------------------------------------
# --cli-input-json from a file keeps the value out of argv. `--rawfile` is jq's way of reading
# a value from a file rather than an argument, for the same reason.
jq -n \
  --arg name "$PARAMETER" \
  --arg key "$KMS_KEY_ARN" \
  --rawfile token "$WORKDIR/token" \
  '{
     Name:      $name,
     Value:     ($token | sub("\n+$"; "")),
     Type:      "SecureString",
     KeyId:     $key,
     Overwrite: true,
     Tier:      "Standard"
   }' > "$WORKDIR/put.json"

if ! aws ssm put-parameter --region "$REGION" \
     --cli-input-json "file://$WORKDIR/put.json" > /dev/null; then
  log "ERROR: PutParameter failed. Runner $RUNNER_ID exists in GitLab with a token that is now"
  log "ERROR: unrecoverable. Delete it before retrying:"
  log "ERROR:   DELETE $GITLAB_URL/api/v4/runners/$RUNNER_ID"
  exit 1
fi

# Non-secret companions, written after the token so their presence implies the token landed.
aws ssm put-parameter --region "$REGION" --name "$ID_PARAMETER" \
  --type String --overwrite --value "$RUNNER_ID" > /dev/null
aws ssm put-parameter --region "$REGION" --name "$EXPIRY_PARAMETER" \
  --type String --overwrite --value "$TOKEN_EXPIRES_AT" > /dev/null

log "wrote $PARAMETER (SecureString, key $KMS_KEY_ARN)"
log "done. Terraform never saw the token."
