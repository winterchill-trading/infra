#!/usr/bin/env bash
# Check that a repo's CI pins every sibling package it needs, in dependency
# order, by reading the dune-project files of the checkouts next to it.
#
#   scripts/check-pins.sh [-s] REPO_DIR...
#   scripts/check-pins.sh [-s] -a            # every repo in the workspace
#
#   -s   also print the expected pin lines, in a valid order
#   -a   check every sibling that has a dune-project and a ci.yml
#
# Env:
#   WORKSPACE=..    directory holding the sibling checkouts (default: the
#                   parent of this infra checkout)
#   ORG=winterchill-trading
#
# A sibling package is any package declared in a dune-project under
# WORKSPACE. For each repo the required pins are the transitive sibling
# dependencies of its own packages: their test dependencies count (CI installs
# with --with-test), a dependency's test dependencies do not, as opam only
# applies --with-test to the packages named on the command line. A repo may
# pin its own packages (`opam pin add <pkg> .`); those are not checked. The check fails on a missing pin, a pin that
# comes before one of its own sibling dependencies, or a pin whose URL is not
# the repo declaring the package. Unneeded pins are reported but pass.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
workspace=${WORKSPACE:-$(cd "${here}/../.." && pwd)}
org=${ORG:-winterchill-trading}
suggest=0 all=0

while getopts "sa" opt; do
  case ${opt} in
    s) suggest=1 ;;
    a) all=1 ;;
    *) echo "usage: $0 [-s] [-a | REPO_DIR...]" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

repos=()
if [[ ${all} == 1 ]]; then
  for d in "${workspace}"/*/; do
    d=${d%/}
    [[ -f ${d}/dune-project && -f ${d}/.github/workflows/ci.yml ]] && repos+=("${d}")
  done
else
  repos=("$@")
fi
if [[ ${#repos[@]} == 0 ]]; then
  echo "usage: $0 [-s] [-a | REPO_DIR...]" >&2
  exit 2
fi

# Emit "PKG <repo> <package>" and "DEP <package> <dependency> <run|test>"
# for one dune-project. A small s-expression reader: strings, comments and nested
# constraint lists like (core (>= v0.17)) or (ppx_expect :with-test).
parse_dune_project() {
  awk -v repo="$1" '
    function atom(a,   is_head) {
      is_head = first[depth]
      if (is_head) { head[depth] = a; first[depth] = 0 }
      if (head[depth - 1] == "package" && head[depth] == "name" && !is_head) name = a
      else if (head[depth - 1] == "package" && head[depth] == "depends" && !is_head) { deps[++ndeps] = a; kind[ndeps] = "run" }
      else if (is_head && head[depth - 1] == "depends" && head[depth - 2] == "package") { deps[++ndeps] = a; kind[ndeps] = "run"; dep_depth = depth }
      else if (dep_depth && depth >= dep_depth && (a == ":with-test" || a == ":with-doc")) kind[ndeps] = "test"
    }
    { text = text $0 "\n" }
    END {
      n = length(text); depth = 0; i = 1
      while (i <= n) {
        c = substr(text, i, 1)
        if (c == ";") { while (i <= n && substr(text, i, 1) != "\n") i++; continue }
        if (c == "(") { depth++; first[depth] = 1; head[depth] = ""; i++; continue }
        if (c == ")") {
          if (head[depth] == "package" && depth == 1) {
            print "PKG", repo, name
            for (k = 1; k <= ndeps; k++) print "DEP", name, deps[k], kind[k]
            name = ""; ndeps = 0
          }
          if (depth == dep_depth) dep_depth = 0
          depth--; i++; continue
        }
        if (c ~ /[ \t\n\r]/) { i++; continue }
        if (c == "\"") {
          s = ""; i++
          while (i <= n && substr(text, i, 1) != "\"") {
            if (substr(text, i, 1) == "\\") i++
            s = s substr(text, i, 1); i++
          }
          i++; atom(s); continue
        }
        s = ""
        while (i <= n && substr(text, i, 1) !~ /[ \t\n\r();"]/) { s = s substr(text, i, 1); i++ }
        atom(s)
      }
    }' "$2"
}

# Emit "PIN <index> <package> <url>" for every `opam pin add` in a workflow.
parse_pins() {
  awk '
    /opam pin add/ {
      sub(/.*opam pin add/, "")
      m = split($0, w, /[ \t]+/); got = 0
      for (k = 1; k <= m; k++) {
        if (w[k] == "" || w[k] ~ /^-/) continue
        if (got == 0) { pkg = w[k]; got = 1 } else { url = w[k]; got = 2; break }
      }
      if (got == 2) print "PIN", ++idx, pkg, url
    }' "$1"
}

graph=$(mktemp)
trap 'rm -f "${graph}"' EXIT
for d in "${workspace}"/*/; do
  d=${d%/}
  [[ -f ${d}/dune-project ]] && parse_dune_project "$(basename "${d}")" "${d}/dune-project"
done > "${graph}"

status=0
for repo_dir in "${repos[@]}"; do
  repo=$(basename "${repo_dir}")
  ci=${repo_dir}/.github/workflows/ci.yml
  if [[ ! -f ${ci} ]]; then
    echo "${repo}: no .github/workflows/ci.yml" >&2
    status=1
    continue
  fi
  { cat "${graph}"; parse_pins "${ci}"; } | awk \
    -v repo="${repo}" -v org="${org}" -v suggest="${suggest}" '
    $1 == "PKG" { owner[$3] = $2; if ($2 == repo) own[$3] = 1; next }
    $1 == "DEP" { ndep[$2]++; dep[$2, ndep[$2]] = $3; test[$2, ndep[$2]] = ($4 == "test"); next }
    $1 == "PIN" { npin++; pin_pkg[npin] = $3; pin_url[npin] = $4; if (!($3 in pin_at)) pin_at[$3] = $2; next }
    # Depth-first post-order over sibling packages: dependencies first.
    function visit(p,   k, q) {
      if (p in seen) return
      seen[p] = 1
      for (k = 1; k <= ndep[p]; k++) {
        q = dep[p, k]
        if (test[p, k] && !(p in own)) continue
        if ((q in owner) && !(q in own)) visit(q)
      }
      if (!(p in own)) order[++norder] = p
    }
    END {
      for (p in own) roots[++nroots] = p
      # Deterministic order for the suggestion.
      for (a = 1; a <= nroots; a++) for (b = a + 1; b <= nroots; b++)
        if (roots[b] < roots[a]) { t = roots[a]; roots[a] = roots[b]; roots[b] = t }
      for (a = 1; a <= nroots; a++) visit(roots[a])
      bad = 0
      for (k = 1; k <= norder; k++) {
        p = order[k]
        if (!(p in pin_at)) { printf "%s: missing pin %s\n", repo, p; bad = 1 }
        need[p] = 1
      }
      for (i = 1; i <= npin; i++) {
        p = pin_pkg[i]
        if (!(p in owner) || (p in own)) continue
        want = "https://github.com/" org "/" owner[p] ".git"
        u = pin_url[i]; sub(/#.*/, "", u)
        if (u != want && u ".git" != want)
          { printf "%s: pin %s points at %s, expected %s\n", repo, p, pin_url[i], want; bad = 1 }
        if (!(p in need)) printf "%s: unneeded pin %s (warning)\n", repo, p
        for (k = 1; k <= ndep[p]; k++) {
          q = dep[p, k]
          if (!test[p, k] && (q in pin_at) && pin_at[q] > i)
            { printf "%s: pin %s comes before its dependency %s\n", repo, p, q; bad = 1 }
        }
      }
      if (!bad) printf "%s: ok (%d sibling pins)\n", repo, norder
      if (suggest)
        for (k = 1; k <= norder; k++)
          printf "      - run: opam pin add -y -n %s https://github.com/%s/%s.git\n", order[k], org, owner[order[k]]
      exit bad
    }' || status=1
done
exit "${status}"
