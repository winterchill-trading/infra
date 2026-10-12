# syntax=docker/dockerfile:1.7
#
# OxCaml build image: Ubuntu 24.04, opam, the 5.2.0+ox switch and every
# library the winterchill-trading repos depend on. Service images build
# FROM this and copy the binary into a slim runtime stage.

FROM ubuntu:24.04

ARG TARGETARCH
ARG OPAM_VERSION=2.5.1
# Pin the ox repository so every build resolves the same preview versions.
ARG OX_REPO_COMMIT=afddc8337950dbc02863fe30ae58735a1cf2719f
ARG OCAML_SWITCH=5.2.0+ox

LABEL org.opencontainers.image.source="https://github.com/winterchill-trading/infra" \
      org.opencontainers.image.description="OxCaml toolchain with the Jane Street library stack" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    OPAMROOT=/home/opam/.opam \
    OPAMYES=1 \
    OPAMCONFIRMLEVEL=unsafe-yes \
    OPAMDEPEXTYES=0 \
    OPAMNODEPEXTS=1 \
    OPAMCOLOR=never

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# System packages: compiler toolchain, opam's own needs, and the C libraries
# behind async_ssl (openssl), zstd, zarith (gmp) and ctypes (libffi).
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      autoconf automake bubblewrap build-essential ca-certificates curl git \
      libffi-dev libgmp-dev libssl-dev libzstd-dev m4 patch pkg-config rsync \
      unzip zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

RUN case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /usr/local/bin/opam \
      "https://github.com/ocaml/opam/releases/download/${OPAM_VERSION}/opam-${OPAM_VERSION}-${arch}-linux" \
 && chmod 0755 /usr/local/bin/opam

# The ubuntu image ships a uid 1000 user; replace it with `opam`.
RUN userdel -r ubuntu 2>/dev/null || true \
 && useradd -m -u 1000 -s /bin/bash opam
USER 1000:1000
WORKDIR /home/opam

# Compiler layer: the OxCaml compiler builds from source (the slow part).
RUN opam init --bare --disable-sandboxing --no-setup default https://opam.ocaml.org \
 && opam repo add --dont-select ox \
      "git+https://github.com/oxcaml/opam-repository.git#${OX_REPO_COMMIT}" \
 && opam switch create "${OCAML_SWITCH}" --repos ox,default \
 && opam clean -a -c -s --logs

ENV OPAM_SWITCH_PREFIX=/home/opam/.opam/${OCAML_SWITCH} \
    CAML_LD_LIBRARY_PATH=/home/opam/.opam/${OCAML_SWITCH}/lib/stublibs:/home/opam/.opam/${OCAML_SWITCH}/lib/ocaml/stublibs:/home/opam/.opam/${OCAML_SWITCH}/lib/ocaml \
    OCAML_TOPLEVEL_PATH=/home/opam/.opam/${OCAML_SWITCH}/lib/toplevel \
    PATH=/home/opam/.opam/${OCAML_SWITCH}/bin:${PATH}

# Library layer: union of the dependencies across the org's repos.
# async_websocket must be the ox preview; plain resolution can pick the
# empty v0.13.0 stub. Source downloads (GitHub archives) intermittently
# answer 504, so retry the whole install a few times.
# hadolint ignore=SC2086
RUN pkgs="dune core core_unix async async_ssl \
      async_websocket.v0.18~preview.130.106+341 \
      cohttp-async conduit-async uri yojson cryptokit zstd \
      ppx_jane ppx_expect ppx_inline_test ppx_yojson_conv \
      base_quickcheck bin_prot" \
 && for attempt in 1 2 3; do \
      OPAMRETRIES=5 opam install ${pkgs} && break; \
      if [ "${attempt}" = 3 ]; then exit 1; fi; \
      echo "opam install failed (attempt ${attempt}), retrying" >&2; sleep 30; \
    done \
 && opam clean -a -c -s --logs \
 && test -f "${OPAM_SWITCH_PREFIX}/lib/async_ssl/META" \
 && ls "${OPAM_SWITCH_PREFIX}"/lib/async_websocket/*.cmi > /dev/null

CMD ["bash"]
