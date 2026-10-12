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
- A repo whose two packages depend on each other through a sibling (exchange-core:
  exchange-core-engine needs order-book, which needs exchange-core) cannot run
  `--deps-only` over both opam files, and no `opam` exists before the action to pin
  the checkout first. exchange-core copies `exchange-core-engine.opam` into
  `_ox-engine/`, runs the action with `working-directory: _ox-engine` and pins for
  fixed-decimal, exchange-core and order-book, then runs `opam pin add exchange-core .`
  (rebuilds exchange-core and order-book from the checkout, about 15 seconds) and builds
  with `--only-packages exchange-core-engine`.
- Outputs: `cache-hit` (`exact`, `partial` or `none`) and `cache-key`.

Workflows reference the action as `@main` on purpose: it lives in this org's own infra
repository, which only org admins can write to, so a fix reaches every repo on its next
run. Third-party actions (`actions/*`, `ocaml/setup-ocaml`) stay pinned to a version.

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

1. **exact**: same key. Nothing is pinned or installed. Only the system packages the
   installed opam packages declare (`opam list --installed --depexts`) are installed
   with apt, because they live outside the cached switch (`libsecp256k1-dev` for
   `hl-client`).
2. **partial**: the newest entry with the same compiler, ox commit and pin names
   (`restore-keys` stops before the pin commits). The switch remembers the commits it
   was built with (`_opam/.ox-setup-pins`); the action re-pins, `opam reinstall`s only
   the pins whose commit moved (opam rebuilds their installed dependents with them),
   installs any new dependencies, and saves under the new key.
3. **none**: the full dependency build, on top of setup-ocaml's own compiler cache.

## When the cache misses or breaks

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
- An exact hit runs no opam install or pin at all. It used to run `opam install --deps-only` as
  a "no-op" check, but setup-ocaml selects the `builtin-0install` solver, which on a
  populated switch picked sedlex 3.6+ox over the installed 3.7+ox (sedlex comes in
  through core_bench -> command_nodejs -> js_of_ocaml-compiler, so only repos with
  core_bench as a test dependency were hit), recompiled cohttp, conduit and venue-net,
  and then failed (exit 40) to refetch the venue-net pin.
- Partial hits and misses use `OPAMEXTERNALSOLVER=builtin-mccs+glpk`, which keeps
  installed versions where it can.
- Git checkouts of pins restored from the cache cannot be synchronised again (opam looks
  for `refs/remotes/opam-ref-<commit>`, which is gone), so `opam pin add` failed on a
  partial hit. The action deletes `_opam/.opam-switch/sources` before re-pinning; each
  pin is cloned afresh (a few seconds each).

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

## Rollout

Every repo except mm-core, market-recorder, specs and infra itself moved to the action on
2026-10-12 (hl-sim was the pilot). Seconds on `ubuntu-latest`. Cold is the first run: no
switch cache, setup-ocaml's compiler cache warm. Warm is a rerun of the same commit (exact
hit, after the two fixes above). exchange-core's build column leaves out its 15 second
re-pin step.

| Repo | Pins | Cold: ox-setup | Cold: job | Warm: ox-setup | Warm: dune build + test | Warm: job |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| fixed-decimal | 0 | 1077 | 1093 | 79 | 19 | 105 |
| exchange-core | 3 | 779 | 815 | 83 | 15 | 106 |
| hl-protocol | 2 | 576 | 594 | 82 | 14 | 101 |
| order-book | 2 | 762 | 775 | 70 | 18 | 92 |
| venue-net | 0 | 1031 | 1047 | 68 | 17 | 89 |
| parquet | 0 | 824 | 844 | 67 | 19 | 92 |
| market-data | 3 | 1009 | 1051 | 89 | 37 | 133 |
| binance-protocol | 2 | 798 | 828 | 102 | 28 | 136 |
| bybit-protocol | 2 | 762 | 785 | 69 | 19 | 93 |
| equities-core | 2 | 531 | 543 | 110 | 11 | 130 |
| hl-client | 6 | 1063 | 1088 | 78 | 17 | 100 |
| binance-sim | 5 | 868 | 884 | 94 | 12 | 110 |
| bybit-sim | 5 | 1029 | 1048 | 105 | 13 | 125 |
| nyse-sim | 5 | 721 | 739 | 92 | 19 | 118 |
| cboe-sim | 5 | 858 | 881 | 93 | 22 | 121 |
| cme-sim | 5 | 786 | 808 | 69 | 23 | 96 |
| bitget-feed | 5 | 1163 | 1187 | 99 | 15 | 121 |
| coinbase-feed | 5 | 1194 | 1216 | 122 | 16 | 146 |
| deribit-feed | 5 | 938 | 958 | 95 | 17 | 118 |
| kraken-feed | 5 | 962 | 982 | 69 | 18 | 92 |
| okx-feed | 5 | 1135 | 1154 | 120 | 17 | 144 |
| hl-mm | 11 | 884 | 927 | 117 | 19 | 141 |
| binance-client | 10 | 1074 | 1103 | 93 | 19 | 117 |
| bybit-client | 10 | 1210 | 1235 | 74 | 19 | 98 |
| market-maker | 13 | 1007 | 1029 | 120 | 17 | 145 |

Cold runs took 9 to 21 minutes, warm runs 1.5 to 2.5 minutes. A partial hit (hl-sim with
hl-protocol pinned at an older commit, after both fixes) took 122 seconds in ox-setup and
rebuilt only hl-protocol.
