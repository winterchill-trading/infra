# syntax=docker/dockerfile:1.7
#
# Generic service image for one winterchill-trading binary.
#
#   docker buildx build --build-arg REPO=hl-sim --build-arg BIN=hl-sim images/service
#
# The repo is cloned from GitHub at REF, unless a local checkout is passed as
# the `src` build context (`--build-context src=../hl-sim`), which is what the
# Tiltfile does for live rebuilds. Sibling libraries are pinned from GitHub in
# the order the repo's own CI pins them.

ARG BASE_IMAGE=ghcr.io/winterchill-trading/oxcaml-base:latest
ARG RUNTIME_IMAGE=ubuntu:24.04

# Empty unless overridden with --build-context src=<path>.
FROM scratch AS src

FROM ${BASE_IMAGE} AS build
ARG REPO
ARG BIN
ARG REF=main
ARG ORG=winterchill-trading
WORKDIR /home/opam/src
COPY --chown=1000:1000 --from=src / /home/opam/src/
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN test -n "${REPO}" && test -n "${BIN}" \
 && if [ ! -f dune-project ]; then \
      git clone --depth 1 --branch "${REF}" "https://github.com/${ORG}/${REPO}.git" . ; \
    fi \
 && { git rev-parse --short HEAD 2>/dev/null || echo local; } > /home/opam/revision
# Pin siblings exactly as CI does: every `opam pin add <name> <url>` line.
RUN --mount=type=cache,target=/home/opam/.opam/download-cache,uid=1000,gid=1000 \
    grep -hoE 'opam pin add .*' .github/workflows/ci.yml \
    | grep -oE '[a-z0-9_-]+ https://[^ ]+' \
    | while read -r pkg url; do \
        echo "pin ${pkg} ${url}"; \
        opam pin add --no-action --yes "${pkg}" "${url}"; \
      done \
 && opam install . --deps-only --yes
RUN opam exec -- dune build --release @install \
 && mkdir -p /home/opam/out \
 && cp "_build/install/default/bin/${BIN}" /home/opam/out/service

FROM ${RUNTIME_IMAGE} AS runtime
ARG REPO
ARG BIN
# Extra apt packages for the runtime, e.g. `rclone` for the recorder's
# upload command.
ARG RUNTIME_PACKAGES=""
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl libffi8 libgmp10 libssl3t64 libzstd1 ${RUNTIME_PACKAGES} \
 && rm -rf /var/lib/apt/lists/* \
 && userdel -r ubuntu 2>/dev/null || true \
 && useradd -r -u 10001 -m -d /var/lib/service service
COPY --from=build /home/opam/out/service /usr/local/bin/service
COPY --from=build /home/opam/revision /etc/service-revision
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN ln -s /usr/local/bin/service "/usr/local/bin/${BIN}" \
 && ! ldd /usr/local/bin/service | grep 'not found'
LABEL org.opencontainers.image.source="https://github.com/winterchill-trading/infra" \
      org.opencontainers.image.title="${REPO}"
USER 10001:10001
WORKDIR /var/lib/service
ENTRYPOINT ["/usr/local/bin/service"]
