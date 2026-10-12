# shellcheck shell=bash
# Helpers shared by the test actions. Sourced, not run.
set -euo pipefail

infra=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compose=(docker compose -f "${infra}/compose/docker-compose.yml")
recorder_url=http://localhost:${RECORDER_PORT:-9100}

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "FAIL: $*"; exit 1; }

# Sum of a recorder metric, optionally over the series matching a label
# substring: metric market_recorder_frames_total 'venue="hyperliquid"'.
metric() {
  curl -sf "${recorder_url}/metrics" \
    | awk -v name="$1" -v match_="${2:-}" '
        $1 == name || index($1, name "{") == 1 {
          if (match_ == "" || index($1, match_)) { sum += $2; found = 1 }
        }
        END { if (!found) sum = 0; printf "%d\n", sum }'
}

healthz_code() {
  curl -s -o /dev/null -w '%{http_code}' "${recorder_url}/healthz" || true
}

# wait_for SECONDS DESCRIPTION COMMAND...: poll COMMAND every second.
# Logs how long it took.
wait_for() {
  local start=${SECONDS} limit=$1 what=$2
  shift 2
  until "$@"; do
    ((SECONDS - start < limit)) || die "timed out after ${limit}s waiting for ${what}"
    sleep 1
  done
  log "${what} (after $((SECONDS - start))s)"
}

healthy() { [[ $(healthz_code) == 200 ]]; }

require_stack() {
  "${compose[@]}" ps --status running --services | grep -qx market-recorder \
    || die "the compose stack is not running (make up)"
  wait_for 120 "recorder healthy" healthy
}

# Objects in the MinIO bucket, counted with mc inside the minio container.
uploaded_objects() {
  # shellcheck disable=SC2016
  "${compose[@]}" exec -T minio sh -c \
    'mc alias set l http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null && mc ls -r l/market-data | wc -l' \
    | tr -d ' '
}
