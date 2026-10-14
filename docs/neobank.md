# Neobank demo, locally

The neobank demo ([neobank-api](https://github.com/winterchill-trading/neobank-api),
[neobank-web](https://github.com/winterchill-trading/neobank-web)) runs in the compose
`neobank` profile on the fake banking provider: offline, no credentials, no real money.
Application state is in the `neobank` Postgres database.

```sh
make up-neobank     # builds both images (first run: long, see local.md), then starts them
open http://localhost:8200/
make down           # containers go, data stays
```

Ports are overridable: `NEOBANK_WEB_PORT=8201 NEOBANK_API_PORT=8281 PG_PORT=5433 make
up-neobank`. The web app's `/api/` proxy reaches the API inside the compose network, so
the API's host port does not matter to the browser.

## Services

| Service | Image | What it does | Host port |
| --- | --- | --- | --- |
| `postgres` | `postgres:18-alpine` | The `neobank` database ([local.md](local.md#databases)); the API applies its migrations at startup | 127.0.0.1:5432 |
| `neobank-api` | `neobank-api` (with `libpq5`) | `-provider fake -store postgres -state-dir /var/lib/neobank-api/state`; `/healthz`, `/metrics`, `/ws` | 8280 |
| `neobank-web` | `neobank-web` (web target) | The js_of_ocaml app (`index.html`, `main.js`) on nginx, the API proxied under `/api/` (`compose/neobank-web-nginx.conf`); healthy when `/api/healthz` answers through the proxy | 8200 |

With no query the app calls `/api` on its own origin; `/?mock=1` runs on its built-in
mock bank instead.

Data lives in two places that belong together: the `neobank` database (customers,
accounts, transfers, ...) and the `neobank-state` volume (the fake bank's ledger
journal). Both survive `make down`. `make reset-neobank CONFIRM=yes` drops and recreates
the database and deletes the volume, leaving `hl_copy` and the other volumes alone;
`make reset-data CONFIRM=yes` deletes everything.

## Settings

| Variable | Default | |
| --- | --- | --- |
| `NEOBANK_WEB_PORT` | 8200 | Web app; also the API's `-allow-origin` |
| `NEOBANK_API_PORT` | 8280 | API, directly |
| `NEOBANK_PROVIDER` | `fake` | `striga` once neobank-api links it (not yet) |
| `NEOBANK_OPS_TOKEN` | unset | Bearer token for `/ops/*` (operator review queue); unset hides those routes |
| `STRIGA_*` | unset | Striga sandbox credentials, passed through only when set in your shell |
| `NEOBANK_DB_PASSWORD` | `neobank-dev` | Password of the `neobank` role, set once when the data directory is created |

`DATABASE_URL` ends in `?sslmode=disable`: pg-async requires TLS otherwise, and the
local Postgres has none.

## Smoke test

neobank-web's live smoke drives the compiled app over real HTTP through nine steps
(sign-up, KYC, deposit, SEPA payment with SCA, swap, card, standing order, statement,
a held payment approved by an operator). Against the compose stack, through the nginx
proxy:

```sh
NEOBANK_OPS_TOKEN=smoke-ops make up-neobank
cd ../neobank-web
API_URL=http://localhost:8200/api OPS_TOKEN=smoke-ops scripts/live-smoke.sh
# all 9 live steps passed in 7975 ms; 103 API requests   (2026-10-14)
```

The script builds `main.bc.js` with dune from the workspace (`OPAMSWITCH`,
`DUNE_BUILD_DIR` as usual) and needs `node`.

## Known issue: sign-up after an API restart

The fake provider numbers its customers from `cus_000001` again after neobank-api
restarts, while the database still holds the earlier ones. The next sign-up's
`create_customer` fails on `customers_provider_ref_key` and its KYC stays at
`provider_pending` (409 on `/kyc/start`). Until neobank-api restores the counter,
`make reset-neobank CONFIRM=yes` before starting the API again gives a clean pair.
Existing customers keep working; only new sign-ups are affected.
