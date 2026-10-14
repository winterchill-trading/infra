# AGENTS.md (infra)

## Purpose

Container images, the local compose stack, the Helm chart, the shared CI pieces (the `ox-setup`
action and the `obj-magic` workflow), and the deployment notes for the OxCaml services. This is not
an OCaml repository: there is no opam package and no dune project here.

Workspace-wide rules, the repository map and the CI model are in
`../oxcaml-claude-skills/AGENTS.md`. Read that first.

## Layout

| Path | Holds |
| --- | --- |
| `images/oxcaml-base/` | The base image: Ubuntu, opam, the `5.2.0+ox` switch with the org's libraries ([images/AGENTS.md](images/AGENTS.md)) |
| `images/service/` | `Dockerfile` and `build.sh`: one multi-stage build for any service binary, pinned to resolved commits |
| `compose/` | Local stack: simulators, market maker, recorder, MinIO, PostgreSQL, monitoring, copy-trading and neobank profiles ([compose/AGENTS.md](compose/AGENTS.md)) |
| `charts/winterchill/` | Helm chart: recorders, day close, simulators, copy trading, PostgreSQL ([charts/AGENTS.md](charts/AGENTS.md)) |
| `.github/` | Workflows and the `ox-setup` action ([.github/AGENTS.md](.github/AGENTS.md)) |
| `docs/` | Local and AWS notes, copy trading, the neobank demo, the recorder runbook, CI, images ([docs/AGENTS.md](docs/AGENTS.md)) |
| `scripts/` | `check-pins.sh` (CI pins against `dune-project`), `ps.sh`, `gc-compare.sh` |
| `test-actions/` | Chaos checks against a running local stack: orders, recorder restart, network cut, upload outage |
| `Makefile` | Every operator and CI entry point (`make help` lists them) |
| `Tiltfile` | Live rebuild of service images on a local Kubernetes cluster |

## Build, test, docs

There is no dune build. The checks, run from this repository:

```sh
make lint     # hadolint, shellcheck, check-pins fixtures, the chart copy diff, helm lint
make pins     # every sibling checkout's CI pins against its dune-project
make base     # build the base image for the host architecture
make build    # build every service image in the compose stack
make up       # build and start the local stack; make ps shows commits and pins
make chart    # re-render charts/rendered-example.yaml from values-dev.yaml
```

`make lint` is the check to run before a commit; it passes on a clean checkout. `make pins` reads the
sibling checkouts next to this one, so run it inside the workspace. Docs live in `docs/` and are
plain Markdown; there is no docs build.

## Conventions

- Images are pinned to commits, never `latest`. The chart's defaults reference the commit-tagged
  images; a `latest` in a values file is a bug.
- The compose init script and the chart's copy (`charts/winterchill/files/postgres/10-databases.sh`)
  must stay identical; `make lint` diffs them.
- Hot binaries are built with flambda2 `-O3` (the default for sims and the market maker). Compare
  with the `o3-compare` workflow before changing it.
- Repo CI goes through `ox-setup`, not hand-written `opam pin` steps. Docs for the cache key and
  its misses are in `docs/ci.md`.
- Comments explain each pinned version, timeout or workaround, what and why.

## Dependencies and dependents

- Every OCaml repository's CI calls `.github/actions/ox-setup` and, for the Obj.magic check, the
  reusable `.github/workflows/obj-magic.yml`.
- The images run the services of the org repositories: `hl-sim`, `binance-sim`, `bybit-sim`,
  `market-maker`, `market-recorder`, `hl-leaderboard`, `hl-copy-engine`, `hl-copy-api`, `neobank-api`,
  `hl-mm`, and the copy-trading web app as a static site.
- Specs: `../specs/repos/infra.md`, `../specs/design/deployment.md` and `../specs/design/cloud-sinks-and-replication.md`.

## CI

`.github/workflows/ci.yml` runs `lint` (hadolint 2.15.1, shellcheck, the pin fixtures, the chart
copy check and `helm lint`), `helm`, `compose`, an `ox-setup` exercise against `hl-sim` with a
pinned older `hl-protocol`, and `obj-magic`. `base-image.yml` builds the base image on push and on a
schedule. `service-images.yml` is manual: it pushes multi-arch images to GHCR tagged with each repo's
commit. `o3-compare.yml` and `proctopus.yml` are manual benchmarks and a terminal-UI check.

Check a run with one `gh run list --limit 1` and at most one `gh run watch <id> --exit-status`.
Never poll in a loop.

## Pitfalls

- Core's `Time_ns` fails at startup without local time data. Runtime images need `tzdata` and a UTC
  setting.
- An Async binary running as PID 1 ignores SIGTERM. Run it under `tini`, or pods wait out the grace
  period.
- `RUN git clone` layers are cached forever. Use `ADD` with a ref to re-check the remote, and bump the
  pin epoch build argument to bust the sibling pin cache.
- hadolint 2.12 rejects `ADD --keep-git-dir`. The lint job downloads 2.15 or later.
- GHCR makes a new package private even when the repository is public. Set the source label in the
  Dockerfile and in the build-push labels so the package links to the repo and inherits visibility; an
  existing package has to be changed in the web UI.
- OxCaml under emulation is too slow for multi-arch builds. Build each architecture on a native runner
  and merge the digests.

## Where to read more

- `README.md`, `docs/`, `../specs/repos/infra.md`, `../specs/design/deployment.md`
- `../oxcaml-claude-skills/AGENTS.md`, `../oxcaml-claude-skills/GOTCHAS.md` (the Containers section)
- Skill: `../oxcaml-claude-skills/skills/oxcaml-setup` for the switch and the ox repository pin

## Never do

- Change the OCaml compiler, `core`, `base`, `async` or `ppx_jane` versions on the shared switch.
  Dry-run first: `opam install --switch 5.2.0+ox --dry-run <pkg>`.
- Publish, tag or release images or charts, or run a manual `service-images` push, without being asked.
- Commit credentials. Registry tokens and cloud keys come from the environment or the CI secret store.
- Print secrets, tokens or the contents of a values file that holds them.
- Run `make down` or `make reset-data` against a stack someone else is using; the reset targets delete
  volumes.
