# CI with the ox-setup action

`.github/actions/ox-setup` replaces the setup-ocaml step, the `opam pin add` lines and
the `opam install --deps-only` step of a repo's `ci.yml`. It installs the OxCaml switch
from the ox opam repository pinned at the base image's commit, pins the siblings at the
commits their default branches point to now, installs the repo's dependencies, and
caches the whole installed switch. A run whose siblings have not moved skips the
dependency build (about 15 minutes for hl-sim) entirely.

## Migrating a repo

Before:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ocaml/setup-ocaml@v3
        with:
          ocaml-compiler: ocaml-variants.5.2.0+ox
          opam-repositories: |
            ox: https://github.com/oxcaml/opam-repository.git#afddc8337950dbc02863fe30ae58735a1cf2719f
            default: https://github.com/ocaml/opam-repository.git
      - run: opam pin add fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git --no-action --yes
      - run: opam pin add exchange-core https://github.com/winterchill-trading/exchange-core.git --no-action --yes
      - run: opam pin add hl-protocol https://github.com/winterchill-trading/hl-protocol.git --no-action --yes
      - run: opam install . --deps-only --with-test
      - run: opam exec -- dune build
      - run: opam exec -- dune test
```

After:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: winterchill-trading/infra/.github/actions/ox-setup@main
        with:
          pins: |
            fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git
            exchange-core https://github.com/winterchill-trading/exchange-core.git
            hl-protocol https://github.com/winterchill-trading/hl-protocol.git
      - run: opam exec -- dune build
      - run: opam exec -- dune test
```

- `pins`: one `name url` per line, in dependency order, the same order as the old
  `opam pin add` lines (`scripts/check-pins.sh -s <repo>` prints it). A url may end in
  `#<branch or commit>`; without one the default branch HEAD is used.
- `with-test` (default `true`): `--with-test` for the repo's own packages.
- `working-directory` (default `.`): where the repo's `*.opam` files are.
- `ox-repository`: defaults to the base image's commit; leave it out so a bump in infra
  reaches every repo.
- A repo that pins its own package first (exchange-core) keeps a
  `opam pin add <pkg> . --no-action` step before the action; the action only pins
  what it is given.
- Outputs: `cache-hit` (`exact`, `partial` or `none`) and `cache-key`.

`scripts/check-pins.sh` reads the `pins: |` block like the old `opam pin add` lines,
and checks the ox commit (the action default counts) against
`images/oxcaml-base/Dockerfile`.

## Cache key

```
ox-setup-v1-<os>-<arch>-<runner image>-<compiler hash>-<ox commit>-<pin names hash>-<pin commits hash>-<opam files hash>
```

- **ox commit**: the `#<commit>` of `ox-repository`; the action refuses an unpinned url.
- **pin names**: the list of pinned package names, in order.
- **pin commits**: each pin resolved with `git ls-remote <url> <ref>` at the start of
  the run. The pins are then added at exactly those commits (`url#<commit>`), so the
  cache content always matches its key even if a sibling is pushed mid-run.
- **opam files**: the repo's `*.opam` files and the `with-test` flag.

The cached path is the setup-ocaml local switch `$GITHUB_WORKSPACE/_opam`, without
`.opam-switch/build` and `.opam-switch/backup`. It is saved by the action itself, right
after the dependencies install, so a failing build or test still leaves a warm cache.

Restore order:

1. **exact**: same key. Nothing is pinned or installed; `opam install --deps-only` runs
   as a no-op check.
2. **partial**: the newest entry with the same compiler, ox commit and pin names
   (`restore-keys` stops before the pin commits). The switch remembers the commits it
   was built with (`_opam/.ox-setup-pins`); the action re-pins, `opam reinstall`s only
   the pins whose commit moved (opam rebuilds their installed dependents with them),
   installs any new dependencies, and saves under the new key.
3. **none**: the full dependency build, on top of setup-ocaml's own compiler cache.

## When the cache misses

- First run of a repo, or of a new pin list (adding or reordering a pin): full miss.
- Any sibling pushes to its default branch: partial hit; the rebuild is the moved
  siblings and everything above them. A push to fixed-decimal rebuilds every sibling
  pin; a push to hl-protocol rebuilds hl-protocol only.
- The ox commit or compiler changes: full miss, and setup-ocaml rebuilds the compiler
  (about 20 minutes) because its own key contains the repository urls.
- An opam file or `with-test` change: partial hit, then `opam install --deps-only`
  adds what is new.
- Caches are per repository and per branch; a branch reads its own entries and the
  default branch's. GitHub evicts entries over 10 GB per repository, least recently
  used first; each switch entry is several hundred MB, so a busy repo keeps roughly the
  last dozen.
- `ubuntu-latest` moving to a new Ubuntu release (`ImageOS`, e.g. `ubuntu24`): full
  miss. Weekly image updates within a release keep the key.

## Timings

The `ox-setup-hl-sim` job in this repo's CI runs the action against an hl-sim checkout
(five sibling pins) on `ubuntu-latest`. Seconds per phase, 2026-10-12:

| Run | setup-ocaml | restore | pins + deps | save | dune build + test | Job |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| cold, compiler not cached (new ox url) | 957 | 0 | 971 | 27 | 17 | 1973 |
| cold, compiler cached | 43 | 0 | 959 | 27 | 16 | 1046 |
| warm, exact hit | 34 | 31 | 2 | - | 23 | 91 |
| partial: hl-protocol pinned two commits back (dispatch input) | 40 | 55 | 27 | 26 | 14 | 163 |

In the partial run only hl-protocol was rebuilt (`opam reinstall hl-protocol`, nothing
in the switch depends on it); a moved fixed-decimal would rebuild the four pins above it
as well. Run `gh workflow run ci.yml -f hl-protocol-ref=<commit>` to repeat it.

hl-sim is the pilot: its own `ci.yml` uses the action since 2026-10-12.

| hl-sim CI | setup-ocaml | restore | pins + deps | save | dune build + test | Job |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| before, setup-ocaml + `opam pin add` | 36-43 | - | 948-954 | - | ~15 | ~1020 |
| first run, compiler not cached (pinned ox url) | 1014 | 0 | 969 | 28 | 15 | 2028 |
| warm, exact hit (rerun) | 39 | 47 | 2 | - | 27 | 117 |

The saved switch is 2.5 GB (zstd tarball; setup-ocaml's compiler-only entry is
1.0 GB) and restores in about 30 seconds. Before the action hl-sim's CI took about
17 minutes on every push.
