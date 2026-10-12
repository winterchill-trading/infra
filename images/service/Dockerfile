# syntax=docker/dockerfile:1.7
#
# Generic service image for one winterchill-trading binary.
#
#   docker buildx build --build-arg REPO=hl-sim --build-arg BIN=hl-sim images/service
#
# The repo is fetched from GitHub at REF, unless a local checkout is passed as
# the `src` build context (`--build-context src=<dir>`, see build.sh), which is
# what the Tiltfile does for live rebuilds. Sibling libraries are pinned from GitHub in
# the order the repo's own CI pins them.

ARG BASE_IMAGE=ghcr.io/winterchill-trading/oxcaml-base:latest
ARG RUNTIME_IMAGE=ubuntu:24.04

# Source tree. BuildKit re-checks the remote ref on every build, so a moved
# branch is picked up; `--build-context src=<dir>` replaces this stage.
FROM scratch AS src
ARG ORG=winterchill-trading
ARG REPO
ARG REF=main
ADD --keep-git-dir=true https://github.com/${ORG}/${REPO}.git#${REF} /

# hadolint ignore=DL3006
FROM ${BASE_IMAGE} AS build
ARG REPO
ARG BIN
# Sibling pins track GitHub main; change this (build.sh passes the date) to
# refetch them instead of reusing the cached layer.
ARG PIN_EPOCH=0
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /home/opam/src
# Dependencies first, from the opam files and the CI pin list only, so a
# source change does not reinstall them.
COPY --chown=1000:1000 --from=src /*.opam ./
COPY --chown=1000:1000 --from=src /.github/workflows/ci.yml ./.github/workflows/ci.yml
# Pin siblings exactly as CI does: every `opam pin add <name> <url>` line.
RUN --mount=type=cache,target=/home/opam/.opam/download-cache,uid=1000,gid=1000 \
    test -n "${REPO}" && test -n "${BIN}" \
 && echo "pins as of ${PIN_EPOCH}" \
 && grep -hoE 'opam pin add .*' .github/workflows/ci.yml \
    | grep -oE '[a-z0-9_-]+ https://[^ ]+' \
    | while read -r pkg url; do \
        echo "pin ${pkg} ${url}"; \
        opam pin add --no-action --yes "${pkg}" "${url}"; \
      done \
 && opam install . --deps-only --yes
COPY --chown=1000:1000 --from=src / ./
RUN { git rev-parse --short HEAD 2>/dev/null || echo local; } > /home/opam/revision \
 && opam exec -- dune build --release @install \
 && mkdir -p /home/opam/out \
 && cp "_build/install/default/bin/${BIN}" /home/opam/out/service

# hadolint ignore=DL3006
FROM ${RUNTIME_IMAGE} AS runtime
ARG REPO
ARG BIN
# Extra apt packages for the runtime, e.g. `rclone` for the recorder's
# upload command.
ARG RUNTIME_PACKAGES=""
# /var/lib/<repo> is created owned by the service user, so a fresh named
# volume mounted there is writable.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl libffi8 libgmp10 libssl3t64 libzstd1 ${RUNTIME_PACKAGES} \
 && rm -rf /var/lib/apt/lists/* \
 && { userdel -r ubuntu 2>/dev/null || true; } \
 && useradd -r -u 10001 -m -d /var/lib/service service \
 && install -d -o 10001 -g 10001 "/var/lib/${REPO}"
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
