#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Take the upload target away and bring it back: disconnect MinIO from the
# compose network, so `minio` stops resolving (a DNS outage, as rclone sees
# it), then reconnect it. Recording must go on; the files closed during the
# outage must stay pending and be uploaded after it.
#
#   test-actions/upload-outage.sh [SECONDS]
. "$(dirname "$0")/lib.sh"

outage=${1:-240}
require_stack
container=$("${compose[@]}" ps -q minio)
network=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "${container}")

restore() { docker network connect --alias minio "${network}" "${container}" 2>/dev/null || true; }
trap restore EXIT

failures_before=$(metric market_recorder_upload_failures_total)
pending_before=$(metric market_recorder_upload_pending)
log "disconnecting minio for ${outage}s (pending ${pending_before}, failures ${failures_before})"
docker network disconnect "${network}" "${container}"
cut_at=${SECONDS}
# rclone retries a failed lookup for about 150 s before it exits non-zero, so
# the failure counter lags; the pending gauge moves within a minute.
piling_up() { (($(metric market_recorder_upload_pending) > pending_before + 2)); }
wait_for 120 "uploads piling up" piling_up
remaining=$((outage - (SECONDS - cut_at)))
((remaining > 0)) && sleep "${remaining}"

pending=$(metric market_recorder_upload_pending)
failures=$(metric market_recorder_upload_failures_total)
code=$(healthz_code)
log "after ${outage}s: pending=${pending} failed rclone runs=$((failures - failures_before)) healthz=${code}"
[[ ${code} == 200 ]] || die "recording stopped during the upload outage"
((pending > 0)) || die "nothing pending after ${outage}s without uploads"
# shellcheck disable=SC2016
listed=$("${compose[@]}" exec -T market-recorder sh -c \
  'grep -o "\.zst" /var/lib/market-recorder/upload-pending.sexp | wc -l' | tr -d ' ')
log "upload-pending.sexp lists ${listed} files"

restore
trap - EXIT
log "minio reconnected"
drained() { (($(metric market_recorder_upload_pending) <= 2)); }
wait_for 600 "backlog drained" drained
log "ok: uploads_total=$(metric market_recorder_uploads_total)"
