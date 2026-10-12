#!/usr/bin/env bash
# `docker compose ps`, then the commit each running service image was built
# from and the commits of the siblings it pinned (labels set by build.sh).
set -euo pipefail

compose=(docker compose -f "$(cd "$(dirname "$0")/.." && pwd)/compose/docker-compose.yml")
"${compose[@]}" ps
ids=$("${compose[@]}" ps -q)
[[ -n ${ids} ]] || exit 0
echo
# shellcheck disable=SC2086
docker inspect --format \
  '{{index .Config.Labels "com.docker.compose.service"}}|{{.Config.Image}}|{{index .Config.Labels "org.opencontainers.image.revision"}}|{{index .Config.Labels "io.github.winterchill-trading.pins"}}' \
  ${ids} | sort | awk -F'|' '
    BEGIN { printf "%-16s %-14s %s\n", "SERVICE", "REVISION", "PINS" }
    {
      rev = $3 == "" ? "-" : substr($3, 1, 12) ($3 ~ /-dirty$/ ? "+" : "")
      n = split($4, p, " ")
      printf "%-16s %-14s %s\n", $1, rev, n ? p[1] : "-"
      for (i = 2; i <= n; i++) printf "%-16s %-14s %s\n", "", "", p[i]
    }'
