#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Restart the recorder (SIGTERM, flush, start again) and check that it comes
# back healthy, keeps recording and drains its uploads.
#
#   test-actions/recorder-restart.sh
. "$(dirname "$0")/lib.sh"

require_stack
objects_before=$(uploaded_objects)
log "uploaded objects before restart: ${objects_before}"

start=${SECONDS}
"${compose[@]}" restart -t 30 market-recorder
log "restart returned after $((SECONDS - start))s"
wait_for 120 "recorder healthy again" healthy

# Counters restart from zero: any frames now come from the new process.
frames_seen() { (($(metric market_recorder_frames_total) > 0)); }
wait_for 30 "new process records frames" frames_seen

# A clean shutdown writes an empty (disconnect) line to every stream that had
# data, into the minute files it compresses on the way out. The image has no
# zstd binary, so decompress on the host when it has one.
if command -v zstd > /dev/null; then
  gaps=0
  # shellcheck disable=SC2016
  for f in $("${compose[@]}" exec -T market-recorder sh -c \
    'find /var/lib/market-recorder/raw -name "*.zst" -mmin -3 | head -100'); do
    n=$("${compose[@]}" exec -T market-recorder cat "${f}" | zstd -dc | grep -c '^$' || true)
    gaps=$((gaps + n))
  done
  ((gaps > 0)) || die "no disconnect lines in the minutes closed at shutdown"
  log "disconnect lines in recently closed minutes: ${gaps}"
fi

more_uploads() { (($(uploaded_objects) > objects_before)); }
wait_for 150 "uploads continue" more_uploads
pending=$(metric market_recorder_upload_pending)
log "ok: upload_pending=${pending}"
