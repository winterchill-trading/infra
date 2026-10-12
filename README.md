# infra

Container images, local compose stack and Helm chart for the winterchill-trading
OxCaml services (venue simulators, market maker, market recorder).

| Path | What |
| --- | --- |
| `images/oxcaml-base/` | Ubuntu 24.04 + opam + the `5.2.0+ox` switch with every library the org uses |
| `images/service/` | Generic multi-stage build for one service binary |
| `compose/` | Local stack: simulators, market maker, recorder, MinIO |
| `charts/winterchill/` | Helm chart for recorders and the daily close job |
| `docs/` | Local (Rancher Desktop) and AWS notes |
| `Tiltfile` | Live rebuild of service images on Rancher Desktop |

## Quick start

```sh
docker pull ghcr.io/winterchill-trading/oxcaml-base:latest   # or: make base
images/service/build.sh hl-sim hl-sim
make up && make ps
helm install winterchill charts/winterchill -f charts/winterchill/values-dev.yaml
```

See [docs/local.md](docs/local.md) for the macOS setup and
[docs/aws.md](docs/aws.md) for the production topology. `make lint` runs the
same checks as CI (hadolint, shellcheck, helm lint).
