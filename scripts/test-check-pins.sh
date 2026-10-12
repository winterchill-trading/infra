#!/usr/bin/env bash
# Fixture tests for check-pins.sh: a throwaway workspace of fake repos.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ws=$(mktemp -d)
trap 'rm -rf "${ws}"' EXIT

# repo NAME 'PACKAGE STANZAS' PINNED...
repo() {
  local name=$1 stanzas=$2
  shift 2
  mkdir -p "${ws}/${name}/.github/workflows"
  printf '(lang dune 3.17)\n; a comment with (parens\n%s\n' "${stanzas}" > "${ws}/${name}/dune-project"
  {
    echo "steps:"
    for p in "$@"; do
      echo "  - run: opam pin add -y -n ${p%%=*} ${p#*=}"
    done
  } > "${ws}/${name}/.github/workflows/ci.yml"
}
url() { echo "$1=https://github.com/winterchill-trading/$2.git"; }

repo base '(package (name base-lib) (synopsis "no (deps) here") (depends ocaml))'
repo mid '(package (name mid) (depends (base-lib (>= 0.1)) (sim :with-test)))'
repo sim '(package (name sim) (depends base-lib))'
repo top '(package (name top) (depends mid (sim :with-test) core))' \
  "$(url base-lib base)" "$(url mid mid)" "$(url sim sim)"
repo missing '(package (name missing) (depends mid))' "$(url mid mid)"
repo misordered '(package (name misordered) (depends mid))' "$(url mid mid)" "$(url base-lib base)"
repo wrongurl '(package (name wrongurl) (depends base-lib))' "$(url base-lib mid)"
repo two '(package (name two-a) (depends base-lib)) (package (name two-b) (depends two-a))' \
  "two-a=." "$(url base-lib base)"

fail=0
expect() {
  local name=$1 code=$2 want=$3 got rc=0
  got=$(WORKSPACE=${ws} "${here}/check-pins.sh" -s "${ws}/${name}" 2>&1) || rc=$?
  if [[ ${rc} != "${code}" || ${got} != *"${want}"* ]]; then
    printf 'FAIL %s: exit %s, output:\n%s\n' "${name}" "${rc}" "${got}"
    fail=1
  else
    echo "ok   ${name}"
  fi
}

expect top 0 "top: ok (3 sibling pins)"
# mid's own test dependency on sim does not reach missing.
expect missing 1 "missing: missing pin base-lib"
expect misordered 1 "misordered: pin mid comes before its dependency base-lib"
expect wrongurl 1 "pin base-lib points at https://github.com/winterchill-trading/mid.git"
expect two 0 "two: ok (1 sibling pins)"
expect missing 1 "opam pin add -y -n base-lib https://github.com/winterchill-trading/base.git
      - run: opam pin add -y -n mid"
exit "${fail}"
