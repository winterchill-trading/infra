#!/usr/bin/env bash
# Pin the resolved siblings and install the repo's opam dependencies.
#
# Env: CACHE_HIT ("true" on an exact cache hit), WITH_TEST, WORKDIR,
# PIN_FILE (from resolve.sh).
#
# A restored switch remembers the pins it was built with in
# _opam/.ox-setup-pins. Pins whose commit moved since are reinstalled, which
# also rebuilds the installed packages that depend on them.
set -euo pipefail

cd "${GITHUB_WORKSPACE:-.}"
state=_opam/.ox-setup-pins
test_flag=()
[[ ${WITH_TEST} == true ]] && test_flag=(--with-test)

# An exact hit already holds everything the key describes. Re-solving it is
# not a no-op: the 0install solver that setup-ocaml selects can pick other
# versions than the installed ones (sedlex 3.7+ox -> 3.6+ox under core_bench),
# and the recompile then fails to refetch git pins from the restored sources.
# System packages (depexts such as libsecp256k1-dev) live outside the cached
# switch, so they are installed on every run from the restored switch's
# package list.
install_depexts() {
  local pkgs
  pkgs=$(opam list --installed --depexts 2>/dev/null | tr '\n' ' ')
  if [[ -n ${pkgs// /} ]] && command -v apt-get >/dev/null; then
    echo "Installing system packages: ${pkgs}"
    # shellcheck disable=SC2086
    sudo apt-get install -y --no-install-recommends ${pkgs}
  fi
}

if [[ ${CACHE_HIT} == true ]]; then
  echo "Exact cache hit: dependencies already installed"
  install_depexts
  exit 0
fi

# mccs keeps installed versions where it can, so a partial hit only rebuilds
# what moved.
export OPAMEXTERNALSOLVER=builtin-mccs+glpk

# Git checkouts of pins restored from the cache cannot be synchronised again
# (opam looks for a refs/remotes/opam-ref-<commit> that is not there), so a
# re-pin fails. Drop them; `opam pin add` clones each pin afresh.
rm -rf _opam/.opam-switch/sources

changed=()
while read -r name target; do
  opam pin add --no-action --yes "${name}" "${target}"
  if [[ -f ${state} ]] && ! grep -qxF "${name} ${target}" "${state}"; then
    changed+=("${name}")
  fi
done < "${PIN_FILE}"
installed=()
for name in "${changed[@]+"${changed[@]}"}"; do
  if opam list --installed --short --silent "${name}"; then
    installed+=("${name}")
  fi
done
if [[ ${#installed[@]} -gt 0 ]]; then
  echo "Rebuilding moved pins: ${installed[*]}"
  opam reinstall --yes "${installed[@]}"
fi

opam install --yes --deps-only "${test_flag[@]+"${test_flag[@]}"}" "./${WORKDIR#./}"
cp "${PIN_FILE}" "${state}"
