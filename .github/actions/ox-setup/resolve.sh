#!/usr/bin/env bash
# Resolve every sibling pin to a commit and compose the switch cache key.
#
# Env: PINS ("name url" lines), OX_REPOSITORY, WITH_TEST, WORKDIR, COMPILER.
# Writes the resolved pins ("name url#commit" lines) to $RUNNER_TEMP and sets
# the step outputs key, restore-prefix and pin-file.
#
# Key: ox-setup-v1-<os>-<arch>-<image>-<compiler>-<ox commit>-<pin list>-<pin commits>-<opam files>
# The restore prefix stops after the pin list, so a run whose siblings moved
# starts from the last switch built with the same pins and only rebuilds what
# changed.
set -euo pipefail

sha() { sha256sum | cut -c1-16; }

ox_commit=${OX_REPOSITORY##*#}
if [[ ${OX_REPOSITORY} != *#* || ! ${ox_commit} =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::ox-repository must end in #<40-hex commit>: ${OX_REPOSITORY}"
  exit 1
fi

pin_file=${RUNNER_TEMP:-/tmp}/ox-setup-pins
: > "${pin_file}"
names=()
while read -r name url extra; do
  [[ -z ${name} || ${name} == \#* ]] && continue
  if [[ -z ${url} || -n ${extra:-} ]]; then
    echo "::error::bad pin line, want \"name url\": ${name} ${url} ${extra:-}"
    exit 1
  fi
  base=${url%%#*}
  ref=HEAD
  [[ ${url} == *#* ]] && ref=${url#*#}
  if [[ ${ref} =~ ^[0-9a-f]{40}$ ]]; then
    # ls-remote cannot look up a commit id; use it as given.
    commit=${ref}
  else
    commit=$(git ls-remote "${base}" "${ref}" | awk 'NR == 1 { print $1 }')
    if [[ -z ${commit} ]]; then
      echo "::error::cannot resolve ${ref} of ${base}"
      exit 1
    fi
  fi
  echo "${name} ${base}#${commit}" >> "${pin_file}"
  names+=("${name}")
done <<< "${PINS}"

pin_list=$(printf '%s\n' "${names[@]+"${names[@]}"}" | sha)
pin_commits=$(sha < "${pin_file}")
opam_files=$(cd "${WORKDIR}" && find . -maxdepth 1 -name '*.opam' -print0 \
  | sort -z | xargs -0 -r cat | { cat; echo "with-test=${WITH_TEST}"; } | sha)

prefix="ox-setup-v1-${RUNNER_OS:-Linux}-${RUNNER_ARCH:-X64}-${ImageOS:-local}-$(echo "${COMPILER}" | sha)-${ox_commit:0:12}-${pin_list}-"
key="${prefix}${pin_commits}-${opam_files}"

echo "Resolved pins:"
cat "${pin_file}"
echo "Cache key: ${key}"
{
  echo "key=${key}"
  echo "restore-prefix=${prefix}"
  echo "pin-file=${pin_file}"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
