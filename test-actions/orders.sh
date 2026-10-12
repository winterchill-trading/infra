#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Place orders: run a one-shot market maker (the market-maker e2e, inside the
# compose network) against one simulator, then check it placed orders and
# that the recorder kept receiving that venue's frames.
#
#   test-actions/orders.sh [hyperliquid|binance|bybit] [SECONDS]
. "$(dirname "$0")/lib.sh"

venue=${1:-hyperliquid} run_for=${2:-30}
case ${venue} in
  hyperliquid) url=http://hl-sim:3000 ;;
  binance) url=http://binance-sim:3300 ;;
  bybit) url=http://bybit-sim:3400 ;;
  *) die "unknown venue ${venue}" ;;
esac

require_stack
frames_before=$(metric market_recorder_frames_total "venue=\"${venue}\"")
log "running market-maker on ${venue} for ${run_for}s (recorder has ${frames_before} ${venue} frames)"

# A separate account from the long-running mm-<venue> service, so the two do
# not cancel each other's orders.
report=$("${compose[@]}" run --rm --no-deps -T \
  -e BINANCE_API_KEY=test-actions -e BYBIT_API_KEY=test-actions \
  "mm-${venue}" -venue "${venue}" -network local -base-url "${url}" \
  -address 0x00000000000000000000000000000000000ac710 -run-for "${run_for}" 2>/dev/null)
echo "${report}"

placed=$(awk '$1 == "orders" { print $2 }' <<< "${report}")
[[ ${placed:-0} -gt 0 ]] || die "market-maker placed no orders"
frames_after=$(metric market_recorder_frames_total "venue=\"${venue}\"")
((frames_after > frames_before)) || die "recorder got no ${venue} frames during the run"
log "ok: ${placed} orders placed; recorder ${venue} frames ${frames_before} -> ${frames_after}"
