# Generic service image for one winterchill-trading binary.
#
#   docker buildx build --build-arg REPO=hl-sim --build-arg BIN=hl-sim images/service
#
# `--build-arg O3=true` builds the pins and the repo at flambda2 -O3
# (docs/images.md has the measured difference per binary).
#
# The repo is fetched from GitHub at REF, unless a local checkout is passed as
# the `src` build context (`--build-context src=<dir>`, see build.sh), which is
# what the Tiltfile does for live rebuilds. Sibling libraries are pinned from GitHub in
# the order the repo's own CI pins them: at the commits build.sh resolved
# (PINS), or at each sibling's default branch when PINS is empty.

ARG BASE_IMAGE=ghcr.io/winterchill-trading/oxcaml-base:latest
ARG RUNTIME_IMAGE=ubuntu:24.04
ARG WEB_IMAGE=nginxinc/nginx-unprivileged:1.29-alpine

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
# "pkg=url#commit ..." from build.sh. Exact commits make the layer cache
# follow the siblings: a moved sibling changes PINS and reinstalls.
ARG PINS=""
# Without PINS, siblings track their default branch; change this to refetch
# them instead of reusing the cached layer.
ARG PIN_EPOCH=0
# true compiles the sibling pins and the repo with OCAMLPARAM='_,O3=1'
# (flambda2 -O3). Libraries already in the base image keep their flags.
ARG O3=false
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# C libraries behind opam depexts the base image lacks: hl-client's
# secp256k1 binding needs libsecp256k1 (pkg-config check in conf-secp256k1).
USER 0:0
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsecp256k1-dev \
 && rm -rf /var/lib/apt/lists/*
USER 1000:1000
WORKDIR /home/opam/src
# Dependencies first, from the opam files and the CI pin list only, so a
# source change does not reinstall them.
COPY --chown=1000:1000 --from=src /*.opam ./
COPY --chown=1000:1000 --from=src /.github/workflows/ci.yml ./.github/workflows/ci.yml
# Pin siblings exactly as CI does: every `opam pin add <name> <url>` line.
RUN --mount=type=cache,target=/home/opam/.opam/download-cache,uid=1000,gid=1000 \
    test -n "${REPO}" \
 && if [ "${O3}" = true ]; then export OCAMLPARAM='_,O3=1'; fi \
 && if [ -n "${PINS}" ]; then \
      tr ' ' '\n' <<< "${PINS}" | sed 's/=/ /'; \
    else \
      echo "pins as of ${PIN_EPOCH}" >&2; \
      { grep -hoE 'opam pin add .*' .github/workflows/ci.yml || true; \
        sed -n '/pins: |/,/^ *[^ ]*:/p' .github/workflows/ci.yml; } \
        | { grep -oE '^ *[a-z0-9_-]+ https://[^ $]+' || true; } | sed 's/^ *//'; \
    fi \
    | while read -r pkg url; do \
        echo "pin ${pkg} ${url}"; \
        opam pin add --no-action --yes "${pkg}" "${url}"; \
      done \
 && opam install . --deps-only --yes
COPY --chown=1000:1000 --from=src / ./
RUN { git rev-parse --short HEAD 2>/dev/null || echo local; } > /home/opam/revision \
 && if [ "${O3}" = true ]; then export OCAMLPARAM='_,O3=1'; fi \
 && opam exec -- dune build --release @install \
 && mkdir -p /home/opam/out \
 && if [ -n "${BIN}" ]; then cp "_build/install/default/bin/${BIN}" /home/opam/out/service; fi

# Runs one of the repo's benches in the build environment, with the same O3
# setting as the build; BIN may be empty for a library repo. Used by the
# o3-compare workflow:
#
#   build.sh order-book "" --target bench-out --build-arg O3=true \
#     --build-arg BENCH='./bench/main.exe -- -quota 2 -ascii' \
#     --output type=local,dest=out
FROM build AS bench
ARG O3=false
ARG BENCH=""
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN --mount=type=cache,target=/home/opam/.opam/download-cache,uid=1000,gid=1000 \
    test -n "${BENCH}" \
 && if [ "${O3}" = true ]; then export OCAMLPARAM='_,O3=1'; fi \
 && opam install . --deps-only --with-test --yes \
 && opam exec -- dune build --release @install \
 && { echo "o3=${O3} $(uname -m) $(nproc) cpus: ${BENCH}"; \
      eval "opam exec -- dune exec --release ${BENCH}"; } 2>&1 \
    | tee /home/opam/bench.txt

FROM scratch AS bench-out
COPY --from=bench /home/opam/bench.txt /

# Static site of a js_of_ocaml app (hl-copy-web): what the repo installs
# under share/<REPO>, served by an unprivileged nginx on port 8080. BIN is
# empty:
#
#   build.sh hl-copy-web "" --target web
#
# The site's nginx config (proxying the API) is mounted by compose and the
# chart, so the image holds only the files.
# hadolint ignore=DL3006
# dune installs share/ files as symlinks into _build/default, and COPY
# --from keeps symlinks as they are, so the site is dereferenced here first
# (a dangling index.html served as 404 on the first compose run).
FROM build AS site
RUN cp -rL /home/opam/src/_build/install/default/share/${REPO} /home/opam/site

FROM ${WEB_IMAGE} AS web
ARG REPO
COPY --from=site /home/opam/site/ /usr/share/nginx/html/
COPY --from=build /home/opam/revision /etc/service-revision
LABEL org.opencontainers.image.source="https://github.com/winterchill-trading/infra" \
      org.opencontainers.image.title="${REPO}"

# hadolint ignore=DL3006
FROM ${RUNTIME_IMAGE} AS runtime
ARG REPO
ARG BIN
ARG O3=false
RUN test -n "${BIN}"
# Core's Time_ns reads /etc/localtime at startup and dies without it, so
# tzdata is required; services run in UTC.
ENV TZ=Etc/UTC
# Extra apt packages for the runtime, e.g. `rclone` for the recorder's
# upload command.
ARG RUNTIME_PACKAGES=""
# /var/lib/<repo> is created owned by the service user, so a fresh named
# volume mounted there is writable.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl libffi8 libgmp10 libsecp256k1-1 libssl3t64 libzstd1 tini tzdata ${RUNTIME_PACKAGES} \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime \
 && { userdel -r ubuntu 2>/dev/null || true; } \
 && useradd -r -u 10001 -m -d /var/lib/service service \
 && install -d -o 10001 -g 10001 "/var/lib/${REPO}"
# DuckDB CLI for binaries that shell out to it (`market-data check` and
# `query`); empty skips it. The release ships one gzipped binary per arch.
ARG DUCKDB_VERSION=""
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN if [ -n "${DUCKDB_VERSION}" ]; then \
      curl -fsSL "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-${TARGETARCH}.gz" \
        | gunzip > /usr/local/bin/duckdb \
      && chmod 755 /usr/local/bin/duckdb \
      && /usr/local/bin/duckdb --version; \
    fi
COPY --from=build /home/opam/out/service /usr/local/bin/service
COPY --from=build /home/opam/revision /etc/service-revision
RUN ln -s /usr/local/bin/service "/usr/local/bin/${BIN}" \
 && ! ldd /usr/local/bin/service | grep 'not found'
LABEL org.opencontainers.image.source="https://github.com/winterchill-trading/infra" \
      org.opencontainers.image.title="${REPO}" \
      io.github.winterchill-trading.o3="${O3}"
USER 10001:10001
WORKDIR /var/lib/service
# tini as PID 1: the kernel drops SIGTERM for a PID 1 without a handler, so
# binaries that rely on the default action would only die on SIGKILL.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/service"]
