#!/usr/bin/env bash
#
# The half of the design that is easy to forget.
#
# `terraform destroy` on the runner stack tears down the instance, the ASG, the VPC and the
# cache bucket. It does NOT delete the SSM parameters (they are not Terraform resources in BYO
# mode) and it does NOT delete the runner registration in GitLab. Without this script, every
# environment teardown leaves a permanently-offline runner in the group's runner list and a
# live token in Parameter Store.
#
# NOTE ON CREDENTIALS: `DELETE /api/v4/runners/:id` is not covered by the `create_runner`
# scope. This script needs a token with `api` scope, or a group Owner-level token. That is a
# real asymmetry in the design — the narrow credential can create but not clean up. Either
# accept a second broader credential used only at teardown, or accept manual cleanup.
#
set -euo pipefail
set +x

usage() {
  echo "usage: deprovision-runner-token.sh --parameter <ssm name> [--region <aws region>]" >&2
  exit 2
}

PARAMETER="" ; REGION="${AWS_REGION:-eu-west-2}"
while [ $# -gt 0 ]; do
  case "$1" in
    --parameter) PARAMETER="$2"; shift 2 ;;
    --region)    REGION="$2"; shift 2 ;;
    *)           usage ;;
  esac
done
[ -n "$PARAMETER" ] || usage
: "${GITLAB_URL:?GITLAB_URL is not set}"
: "${GITLAB_API_TOKEN:?GITLAB_API_TOKEN is not set (needs api scope, not create_runner)}"

ID_PARAMETER="${PARAMETER%/*}/runner-id"
EXPIRY_PARAMETER="${PARAMETER%/*}/token-expires-at"

WORKDIR="$(mktemp -d)"; chmod 700 "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT INT TERM
umask 077
printf 'header = "PRIVATE-TOKEN: %s"\n' "$GITLAB_API_TOKEN" > "$WORKDIR/curlrc"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

RUNNER_ID="$(aws ssm get-parameter --region "$REGION" --name "$ID_PARAMETER" \
  --query 'Parameter.Value' --output text 2>/dev/null || echo "")"

# Delete in GitLab first. If we delete the parameter first and then fail here, we have lost the
# only record of which runner to clean up.
if [ -n "$RUNNER_ID" ]; then
  log "deleting GitLab runner $RUNNER_ID"
  STATUS="$(curl --silent --show-error --config "$WORKDIR/curlrc" \
    --request DELETE --url "$GITLAB_URL/api/v4/runners/$RUNNER_ID" \
    --output /dev/null --write-out '%{http_code}')"
  case "$STATUS" in
    204|404) log "GitLab runner $RUNNER_ID gone (HTTP $STATUS)" ;;
    403)     log "ERROR: HTTP 403 — the token lacks the scope to delete runners. Aborting so the"
             log "ERROR: runner-id parameter is preserved for a manual cleanup."
             exit 1 ;;
    *)       log "ERROR: unexpected HTTP $STATUS deleting runner $RUNNER_ID"; exit 1 ;;
  esac
else
  log "WARN: no runner id recorded at $ID_PARAMETER; skipping GitLab deletion."
  log "WARN: check the group's runner list manually for an offline runner."
fi

for p in "$PARAMETER" "$ID_PARAMETER" "$EXPIRY_PARAMETER"; do
  aws ssm delete-parameter --region "$REGION" --name "$p" >/dev/null 2>&1 \
    && log "deleted $p" \
    || log "WARN: $p not present"
done
