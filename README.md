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
