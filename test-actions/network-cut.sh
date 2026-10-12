#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Cut one simulator off for a while and check that the recorder notices and
# recovers, and that the market maker on that venue survives.
#
#   test-actions/network-cut.sh [hl-sim|binance-sim|bybit-sim] [SECONDS] [pause|disconnect]
#
# pause:      `docker compose pause` freezes the simulator; connections stay
#             open but silent (a black hole: no RST, no FIN).
# disconnect: detaches the simulator from the compose network; its name stops
#             resolving and packets to its old address go nowhere.
. "$(dirname "$0")/lib.sh"

sim=${1:-hl-sim} outage=${2:-45} mode=${3:-pause}
case ${sim} in
  hl-sim) venue=hyperliquid ;;
  binance-sim) venue=binance ;;
  bybit-sim) venue=bybit ;;
  *) die "unknown simulator ${sim}" ;;
esac

require_stack
container=$("${compose[@]}" ps -q "${sim}")
network=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "${container}")
mm=$("${compose[@]}" ps -q "mm-${venue}")
mm_restarts=$(docker inspect -f '{{.RestartCount}}' "${mm}")

restore() {
  case ${mode} in
    pause) "${compose[@]}" unpause "${sim}" 2>/dev/null || true ;;
    disconnect) docker network connect --alias "${sim}" "${network}" "${container}" 2>/dev/null || true ;;
  esac
}
trap restore EXIT

log "cutting ${sim} (${mode}) for ${outage}s"
case ${mode} in
  pause) "${compose[@]}" pause "${sim}" ;;
  disconnect) docker network disconnect "${network}" "${container}" ;;
  *) die "unknown mode ${mode}" ;;
esac
cut_at=${SECONDS}
unhealthy() { [[ $(healthz_code) == 503 ]]; }
wait_for $((outage + 30)) "recorder reports ${venue} stale" unhealthy
remaining=$((outage - (SECONDS - cut_at)))
((remaining > 0)) && sleep "${remaining}"
frames_cut=$(metric market_recorder_frames_total "venue=\"${venue}\"")

restore
trap - EXIT
log "restored ${sim}"
wait_for 300 "recorder healthy after restore" healthy
more_frames() { (($(metric market_recorder_frames_total "venue=\"${venue}\"") > frames_cut)); }
wait_for 60 "${venue} frames flowing again" more_frames

state=$(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "${mm}")
log "mm-${venue}: ${state} (restarts before: ${mm_restarts})"
[[ ${state%% *} == running ]] || die "mm-${venue} is not running"
log "ok"
