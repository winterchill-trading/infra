#!/usr/bin/env bash
# Build a service image for one repo/binary.
#
#   images/service/build.sh REPO BIN [extra buildx args...]
#
# Env:
#   SRC=../hl-sim     build from a local checkout (tracked + untracked,
#                     respecting .gitignore) instead of cloning REF
#   REF=main          git ref to fetch when SRC is unset
#   PIN_EPOCH=...     cache key for the sibling pins (default: today, UTC)
#   BASE_IMAGE=...    base image (default ghcr.io/winterchill-trading/oxcaml-base:latest)
#   TAG=...           image tag (default ghcr.io/winterchill-trading/REPO:local)
#   PLATFORM=...      e.g. linux/amd64,linux/arm64 (default: host, loaded into docker)
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 REPO BIN [buildx args...]" >&2
  exit 2
fi
repo=$1 bin=$2
shift 2

here=$(cd "$(dirname "$0")" && pwd)
tag=${TAG:-ghcr.io/winterchill-trading/${repo}:local}
args=(
  --build-arg "REPO=${repo}"
  --build-arg "BIN=${bin}"
  --build-arg "REF=${REF:-main}"
  --build-arg "PIN_EPOCH=${PIN_EPOCH:-$(date -u +%Y%m%d)}"
  -t "${tag}"
)
[[ -n ${BASE_IMAGE:-} ]] && args+=(--build-arg "BASE_IMAGE=${BASE_IMAGE}")

if [[ -n ${SRC:-} ]]; then
  # Stage only what git would track, so _build directories stay out.
  stage=$(mktemp -d)
  trap 'rm -rf "${stage}"' EXIT
  (cd "${SRC}" && git ls-files -co --exclude-standard -z \
    | xargs -0 tar -cf - --) | tar -xf - -C "${stage}"
  args+=(--build-context "src=${stage}")
fi

if [[ -n ${PLATFORM:-} ]]; then
  args+=(--platform "${PLATFORM}")
else
  args+=(--load)
fi

exec docker buildx build "${args[@]}" "$@" "${here}"
