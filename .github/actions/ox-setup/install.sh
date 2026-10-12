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

if [[ ${CACHE_HIT} != true ]]; then
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
fi

opam install --yes --deps-only "${test_flag[@]+"${test_flag[@]}"}" "./${WORKDIR#./}"
cp "${PIN_FILE}" "${state}"
