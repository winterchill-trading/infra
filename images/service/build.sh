#!/usr/bin/env bash
# Build a service image for one repo/binary.
#
#   images/service/build.sh REPO BIN [extra buildx args...]
#
# The repo commit and every sibling pin from the repo's CI are resolved to
# commits first; the build pins siblings at exactly those commits and records
# them as image labels:
#
#   org.opencontainers.image.revision        repo commit (+ "-dirty" for a
#                                             modified SRC checkout)
#   io.github.winterchill-trading.pins       "pkg=commit12 ..." per sibling pin
#
# Env:
#   SRC=../hl-sim     build from a local checkout (tracked + untracked,
#                     respecting .gitignore) instead of cloning REF
#   REF=main          git ref to fetch when SRC is unset
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

org=winterchill-trading
here=$(cd "$(dirname "$0")" && pwd)
tag=${TAG:-ghcr.io/${org}/${repo}:local}
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

remote_head() {
  git ls-remote "$1" "$2" | awk 'NR == 1 { print $1 }'
}

if [[ -n ${SRC:-} ]]; then
  revision=$(git -C "${SRC}" rev-parse HEAD)
  [[ -n $(git -C "${SRC}" status --porcelain) ]] && revision+=-dirty
  cp "${SRC}/.github/workflows/ci.yml" "${work}/ci.yml"
else
  revision=$(remote_head "https://github.com/${org}/${repo}.git" "${REF:-main}")
  [[ -n ${revision} ]] || { echo "cannot resolve ${REF:-main} in ${repo}" >&2; exit 1; }
  curl -fsSL -o "${work}/ci.yml" \
    "https://raw.githubusercontent.com/${org}/${repo}/${revision}/.github/workflows/ci.yml"
fi

# Same pin lines the Dockerfile falls back to: `opam pin add <pkg> <url>`.
pins=() labels=()
while read -r pkg url; do
  sha=$(remote_head "${url}" HEAD)
  [[ -n ${sha} ]] || { echo "cannot resolve HEAD of ${url}" >&2; exit 1; }
  pins+=("${pkg}=${url}#${sha}")
  labels+=("${pkg}=${sha:0:12}")
done < <(grep -hoE 'opam pin add .*' "${work}/ci.yml" | grep -oE '[a-z0-9_-]+ https://[^ ]+' || true)

args=(
  --build-arg "REPO=${repo}"
  --build-arg "BIN=${bin}"
  --build-arg "REF=${revision%-dirty}"
  --build-arg "PINS=${pins[*]:-}"
  --label "org.opencontainers.image.revision=${revision}"
  --label "io.github.${org}.pins=${labels[*]:-}"
  -t "${tag}"
)
[[ -n ${BASE_IMAGE:-} ]] && args+=(--build-arg "BASE_IMAGE=${BASE_IMAGE}")

if [[ -n ${SRC:-} ]]; then
  # Stage only what git would track, so _build directories stay out.
  stage=${work}/src
  mkdir "${stage}"
  (cd "${SRC}" && git ls-files -co --exclude-standard -z \
    | xargs -0 tar -cf - --) | tar -xf - -C "${stage}"
  args+=(--build-context "src=${stage}")
fi

if [[ -n ${PLATFORM:-} ]]; then
  args+=(--platform "${PLATFORM}")
else
  args+=(--load)
fi

echo "${repo} ${revision}: ${#pins[@]} sibling pins" >&2
docker buildx build "${args[@]}" "$@" "${here}"
