# infra

Container images, local compose stack and Helm chart for the winterchill-trading
OxCaml services (venue simulators, market maker, market recorder).

| Path | What |
| --- | --- |
| `images/oxcaml-base/` | Ubuntu 24.04 + opam + the `5.2.0+ox` switch with every library the org uses |
| `images/service/` | Generic multi-stage build for one service binary |
| `compose/` | Local stack: simulators, market maker, recorder, MinIO; cadvisor, node-exporter and Prometheus under the `monitoring` profile; day close plus `market-data check` under `day-close` |
| `charts/winterchill/` | Helm chart for recorders (optional memtrace), the daily close job with its data-quality check and (optional) node-exporter |
| `docs/` | Local (Rancher Desktop) and AWS notes, [recorder upgrade runbook](docs/runbook-recorder-upgrade.md), [troubleshooting](docs/troubleshooting.md), [runtime tuning and memtrace](docs/runtime-tuning.md), [CI](docs/ci.md) |
| `.github/workflows/obj-magic.yml` | Reusable workflow: `check-obj-magic.sh` over the calling repo, one `uses:` line ([docs/ci.md](docs/ci.md#objmagic-check)) |
| `.github/actions/ox-setup/` | Composite action for repo CI: OxCaml switch, sibling pins and dependencies, cached as one switch ([docs/ci.md](docs/ci.md)) |
| `scripts/check-pins.sh` | Checks each repo's CI pins against the sibling `dune-project` files, and its ox repository commit against the base image (`make pins`) |
| `scripts/ps.sh` | `make ps`: compose status plus each image's commit and sibling pins |
| `scripts/gc-compare.sh` | Peak RSS and CPU of the recorder under different `OCAMLRUNPARAM` settings |
| `test-actions/` | Chaos checks against the running stack: orders, recorder restart, network cut, upload outage ([README](test-actions/README.md)) |
| `Tiltfile` | Live rebuild of service images on Rancher Desktop |

Service images are built by `images/service/build.sh`, which pins the repo and its
siblings at resolved commits, labels the image with them
(`org.opencontainers.image.revision`, `io.github.winterchill-trading.pins`) and tags it
`:<commit12>`. The `service-images` workflow (manual) pushes multi-arch images with
those tags to GHCR; the chart's defaults reference them, never `latest`.

## Quick start

```sh
docker pull ghcr.io/winterchill-trading/oxcaml-base:latest   # or: make base
images/service/build.sh hl-sim hl-sim
make up && make ps          # make up-monitoring for the collectors, make up-day-close, make up-memtrace
helm install winterchill charts/winterchill -f charts/winterchill/values-dev.yaml
```

See [docs/local.md](docs/local.md) for the macOS setup and
[docs/aws.md](docs/aws.md) for the production topology. `make lint` runs the
same checks as CI (hadolint, shellcheck, the check-pins fixtures, helm lint);
`make pins` checks the CI pins of every sibling checkout.

## Repo CI

Repos build with `winterchill-trading/infra/.github/actions/ox-setup@main` in place of
setup-ocaml plus `opam pin add` lines; a run whose siblings have not moved restores the
installed switch and finishes in about 90 seconds instead of 17 minutes. See
[docs/ci.md](docs/ci.md) for the migration, the cache key and when it misses.

Repos add the Obj.magic check as one job:

```yaml
  obj-magic:
    uses: winterchill-trading/infra/.github/workflows/obj-magic.yml@main
```
