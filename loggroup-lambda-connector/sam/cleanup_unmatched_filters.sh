#!/bin/bash
#
# Delete the SumoLGLBDFilter subscription filter from any CloudWatch log group
# that no longer matches the current LogGroupPattern in sam_package.sh.
#
# The SumoLogGroupLambdaConnector only *creates* subscription filters; it has
# no unsubscribe logic. When the allowlist regex tightens, previously-matching
# log groups keep their filters and keep forwarding to SumoLogic until the
# filter is deleted explicitly. This script does that cleanup.
#
# Dry-run by default. Pass --execute to actually delete.
#
# Usage:
#   ./cleanup_unmatched_filters.sh              # dry-run
#   ./cleanup_unmatched_filters.sh --execute    # actually delete unmatched filters
#
# Requirements: awscli v2, xargs (-P). Works on macOS's bash 3.2.

set -euo pipefail

AWS_REGION="us-west-2"
FILTER_NAME="SumoLGLBDFilter"
# CloudWatch Logs rate-limits state-changing calls to ~5 TPS. Keep parallelism
# low to avoid throttling; AWS CLI v2 adaptive retries handle occasional 429s.
PARALLEL=5

# Aggressive retry on throttling for every aws CLI call made by this script.
export AWS_RETRY_MODE=adaptive
export AWS_MAX_ATTEMPTS=10

# Keep in sync with LOG_GROUP_PATTERN in sam_package.sh. Written as a POSIX ERE
# (no negative lookahead needed — this is a pure allowlist).
ALLOWLIST_REGEX='^/aws/(lambda|fargate)/(admin-|alert-generator[-_]|clearwater-|diag-|el_matador-|hermosa-production|hss-etl-|kafka-punches-to-kronos-publisher-production|kafka-to-kronos-exporter|lido-(consumer|api|jobs)-|scheduler-|tabletop[-_]|vendor-|windansea-)'

EXECUTE=false
if [[ "${1:-}" == "--execute" ]]; then
  EXECUTE=true
fi

if $EXECUTE; then
  echo ">>> EXECUTE mode: will DELETE filters from unmatched log groups"
else
  echo ">>> DRY-RUN mode: pass --execute to actually delete"
fi
echo ">>> Region: $AWS_REGION"
echo ">>> Filter: $FILTER_NAME"
echo ">>> Parallelism: $PARALLEL"
echo

echo ">>> Fetching all log groups..."
LOG_GROUPS=$(
  aws logs describe-log-groups \
    --region "$AWS_REGION" \
    --output text \
    --query 'logGroups[].logGroupName' | tr '\t' '\n' | sed '/^$/d'
)
TOTAL=$(echo "$LOG_GROUPS" | wc -l | tr -d ' ')
echo ">>> Found $TOTAL log groups. Checking each for the $FILTER_NAME filter..."
echo ">>> (Log groups without our filter are skipped silently — KEEP/DELETE lines only)"
echo

check_one() {
  local lg="$1"

  # Distinguish real "no filter" from API errors. The earlier version swallowed
  # both into empty-string, so throttled describes looked like "no filter" and
  # log groups were silently skipped.
  local describe_out
  local describe_rc
  describe_out=$(aws logs describe-subscription-filters \
    --log-group-name "$lg" \
    --filter-name-prefix "$FILTER_NAME" \
    --region "$AWS_REGION" \
    --query 'subscriptionFilters[].filterName' \
    --output text 2>&1)
  describe_rc=$?

  if [[ $describe_rc -ne 0 ]]; then
    echo "ERROR-DESCRIBE $lg -- $describe_out" >&2
    return 1
  fi

  if [[ -z "$describe_out" ]]; then
    # Log group genuinely has no filter; progress tick only.
    echo -n "." >&2
    return 0
  fi

  if echo "$lg" | grep -Eq "$ALLOWLIST_REGEX"; then
    echo "KEEP         $lg"
    return 0
  fi

  if [[ "$EXECUTE" != "true" ]]; then
    echo "WOULD-DELETE $lg"
    return 0
  fi

  # Actually delete, verifying the call succeeded. Fall back to reporting a
  # failure line (on stderr) so it's obvious which log groups still need
  # attention after the run.
  local delete_out
  local delete_rc
  delete_out=$(aws logs delete-subscription-filter \
    --log-group-name "$lg" \
    --filter-name "$FILTER_NAME" \
    --region "$AWS_REGION" 2>&1)
  delete_rc=$?

  if [[ $delete_rc -eq 0 ]]; then
    echo "DELETED      $lg"
  else
    echo "FAILED       $lg -- $delete_out" >&2
    return 1
  fi
}

export -f check_one
export AWS_REGION FILTER_NAME ALLOWLIST_REGEX EXECUTE
# AWS_RETRY_MODE and AWS_MAX_ATTEMPTS are already exported above.

echo "$LOG_GROUPS" | xargs -I{} -P "$PARALLEL" bash -c 'check_one "$@"' _ {}

echo
echo
echo ">>> Done. (Each dot on stderr = one log group without our filter.)"
echo ">>> If you saw ERROR-DESCRIBE or FAILED lines on stderr, re-run — those"
echo ">>> log groups were NOT processed. Redirect stderr to a file to capture:"
echo ">>>     ./cleanup_unmatched_filters.sh --execute 2>cleanup.errors"
