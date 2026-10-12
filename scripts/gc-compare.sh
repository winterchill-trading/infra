#!/usr/bin/env bash
# Compare OCAMLRUNPARAM settings by peak RSS and CPU time: one recorder per
# setting, all at once against the simulators of the running compose stack
# (same feed for all), each in its own container with a private data
# directory and no upload. Peak RSS (VmHWM), current RSS and CPU time come
# from /proc of the service process; FRAMES checks they all saw the same feed.
# (v=0x400 prints no GC summary at exit on the 5.2.0+ox runtime.)
#
#   scripts/gc-compare.sh [SECONDS] [SETTING...]
#   scripts/gc-compare.sh 300 o=80 o=120 o=200 s=1M
#
# Env: IMAGE (default ghcr.io/winterchill-trading/market-recorder:local).
set -euo pipefail

run_for=${1:-300}
shift || true
settings=("$@")
[[ ${#settings[@]} -gt 0 ]] || settings=(o=60 o=120 o=200 s=1M)
image=${IMAGE:-ghcr.io/winterchill-trading/market-recorder:local}
network=winterchill_default
docker network inspect "${network}" > /dev/null || { echo "start the stack first (make up)" >&2; exit 1; }

work=$(mktemp -d)
names=()
cleanup() {
  for n in "${names[@]}"; do docker rm -f "${n}" > /dev/null 2>&1 || true; done
  rm -rf "${work}"
}
trap cleanup EXIT

# compose/recorder.sexp without the upload section.
cat > "${work}/recorder.sexp" <<'SEXP'
((data_dir /var/lib/market-recorder)
 (http_port 9100)
 (venues
  (((venue Hyperliquid) (symbols (BTC ETH)) (streams (Trades Bbo L2))
    (config (Custom (base_url http://hl-sim:3000))))
   ((venue Binance) (symbols (BTCUSDT ETHUSDT)) (streams (Trades Bbo L2 Funding))
    (config (Custom (base_url http://binance-sim:3300))))
   ((venue Bybit) (symbols (BTCUSDT ETHUSDT)) (streams (Trades Bbo L2 Funding))
    (config (Custom (base_url http://bybit-sim:3400)))))))
SEXP

for s in "${settings[@]}"; do
  n=gc-compare-${s//[^a-zA-Z0-9]/-}
  names+=("${n}")
  # docker cp rather than a bind mount: the Docker VM may not see the
  # host's temporary directory.
  docker create --name "${n}" --network "${network}" \
    -e "OCAMLRUNPARAM=${s}" \
    "${image}" run -config /etc/recorder.sexp > /dev/null
  docker cp "${work}/recorder.sexp" "${n}:/etc/recorder.sexp"
  docker start "${n}" > /dev/null
done
echo "running ${settings[*]} for ${run_for}s" >&2

# VmHWM/VmRSS (kB) and utime+stime (ticks) of the service process.
sample() {
  docker exec "$1" sh -c '
    for p in /proc/[0-9]*; do
      [ "$(readlink "$p/exe")" = /usr/local/bin/service ] || continue
      awk "/^VmHWM|^VmRSS/ { printf \"%s %s \", \$1, \$2 }" "$p/status"
      awk "{ print \"cpu_ticks\", \$14 + \$15 }" "$p/stat"
    done'
}

sleep "${run_for}"
printf '%-10s %10s %10s %10s %8s\n' SETTING PEAK_RSS_MB RSS_MB CPU_S FRAMES
for i in "${!settings[@]}"; do
  n=${names[$i]}
  read -r _ hwm _ rss _ ticks <<< "$(sample "${n}")"
  frames=$(docker exec "${n}" curl -sf localhost:9100/metrics \
    | awk '/^market_recorder_frames_total/ { s += $2 } END { print s + 0 }')
  awk -v s="${settings[$i]}" -v h="${hwm}" -v r="${rss}" -v t="${ticks}" -v f="${frames}" \
    'BEGIN { printf "%-10s %10.1f %10.1f %10.1f %8d\n", s, h / 1024, r / 1024, t / 100, f }'
done
