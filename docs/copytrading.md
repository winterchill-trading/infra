# Copy trading, locally

The copy-trading platform ([design](https://github.com/winterchill-trading/specs/blob/main/design/copytrading.md))
runs in the compose `copy` profile against hl-sim. Nothing reaches Hyperliquid: the
simulator is the exchange, its leader accounts are the traders to copy, and the
browser wallet only signs.

```sh
make up-copy        # builds the images (first run: long, see local.md), then starts them
open http://localhost:8000/
make down
```

Host ports are overridable when something else listens on them (a tunnel on 3000 or
8080 is common): `HL_SIM_PORT=3010 COPY_API_PORT=8180 make up-copy`. The web app's
`/api/` proxy reaches the API inside the compose network, so the API's host port does
not matter to the browser.

## Services

| Service | Image | What it does | Host port |
| --- | --- | --- | --- |
| `hl-sim` | `hl-sim` | The exchange, with `-leaders 5` (`HL_SIM_LEADERS`) leader accounts trading trend, mean-reversion and random strategies | 3000 |
| `mm-hyperliquid` | `market-maker` | Liquidity on the simulator's books | |
| `hl-leaderboard-collect` | `hl-leaderboard` | Every `LEADERBOARD_INTERVAL` seconds (60): `collect` (the sim's `leaderboard` info request, fills, account state) and `rank` into `leaders.json` | |
| `hl-leaderboard` | `hl-leaderboard` | `serve`: `/leaders`, `/leaders/<address>`, re-reading `leaders.json` when it changes | 8090 |
| `hl-copy-api` | `hl-copy-api` | Wallet login, agent keys and approvals, follows, leader and status proxy, `/ws`, `/metrics` | 8080 |
| `hl-copy-engine` | `hl-copy-engine` | One follower per follow file: leader feed, mirroring, IOC orders; `/metrics`, `/status`, `/healthz` | 127.0.0.1:9930 |
| `hl-copy-web` | `hl-copy-web` (web target) | The js_of_ocaml app on nginx, with the API proxied under `/api/` | 8000 |

Data lives in three volumes: `leaderboard-data` (the collection), `copy-data` (the API's
sealed agent keys, follow records and the follow files the engine watches) and
`copy-journals` (one Bin_prot journal per follow, replayable with
`hl-copy-engine replay`). `make down` drops them.

The first ranking appears after the leaders have traded for a minute or two and one
collect cycle has run; until then the Leaders page is empty. Check with
`curl -s localhost:8090/leaders | head -c 300`.

`HL_COPY_MASTER_KEY` seals the stored agent keys. Compose defaults it to a fixed
development key, which is fine for the simulator and nothing else; set your own with
`HL_COPY_MASTER_KEY=$(openssl rand -hex 32) make up-copy`. Changing it makes the stored
agent keys unreadable, so users approve a new agent.

## Smoke test without a browser

`hl-copy-api/scripts/curl-flow.sh` walks the same flow with a fixed throwaway key signed
by `eth-account` (`PYTHON="uv run -q --with eth-account python3"` works without a venv):

```sh
PYTHON=... API=http://localhost:8080 LEADER=<address from /leaders> \
  hl-copy-api/scripts/curl-flow.sh
curl -s localhost:9930/status      # the follower, its positions, fills and lag
```

The follow it creates allows BTC only; the simulator's leaders mostly trade ETH, so
PATCH the follow's caps (or pick a BTC leader) before expecting fills. A second run
against the same wallet fails on `POST /follows` with a conflict: the follow exists.

## Logging in with a browser wallet

Any EIP-1193 wallet (MetaMask, Rabby, ...) works. Use a fresh throwaway account: the
simulator credits every new address a starting balance, so the account needs no funds
on any chain, and nothing it signs here is valid on Hyperliquid mainnet.

1. Open `http://localhost:8000/`. A bare `/` redirects to `/?api=/api`, which points the
   app at the API through the same origin. (`/?mock=1` shows the built-in mock data
   instead.)
2. **Connect wallet.** The app asks the wallet for an account (`eth_requestAccounts`),
   then `POST /auth/challenge` returns a message naming the address, the origin
   (`http://localhost:8000`, the API's `-public-url`), a single-use nonce and an expiry.
3. **Sign the challenge.** The wallet shows the message as a `personal_sign` request.
   `POST /auth/verify` recovers the signer and returns a session token; the app keeps it
   for the session (24 h).
4. **Leaders.** The ranked table comes from `hl-leaderboard` through the API. Open a
   leader for the equity curve and fills.
5. **Follow.** Pick the scale mode and caps. The API generates an agent key for you,
   seals it, and returns the `approveAgent` typed data; the wallet shows it as an
   `eth_signTypedData_v4` request. The app replaces the domain's chain id with the
   wallet's current chain, because wallets refuse typed data for another chain and
   Hyperliquid accepts any chain id the action carries, so the wallet can stay on
   whatever network it is on. The API submits the signed approval to hl-sim, which
   registers the agent for your account, then writes the follow file.
6. **Dashboard.** Within a scan interval (1 s) the engine starts a follower: it mirrors
   the leader's position changes, scaled to your account, as IOC orders. Positions, pnl,
   pause, resume and stop are on the dashboard. (The API also pushes them over
   `/ws?token=...`, proxied as `/api/ws`; the app polls today.)

Without a browser wallet, `scripts/curl-flow.sh` in hl-copy-api walks the same steps
with a throwaway key: `API=http://localhost:8080 scripts/curl-flow.sh`.

## How orders are signed here

The engine runs with `-unsigned`: its orders carry the follower's address in the
`X-Address` header, which hl-sim accepts because it runs without `-strict-signatures`.
The agent approved in step 5 is real on the simulator (approvals are checked there), but
the engine does not yet load per-user agent keys from the keystore. Against testnet the
engine needs `-agent-key-env` (one agent for every follow) until it does; testnet runs
also need the API's `-exchange-url` and the engine's `-base-url` pointed at testnet,
via `COPY_EXCHANGE_URL`. Both binaries refuse mainnet URLs.

## Monitoring

`make up-monitoring` (or `docker compose --profile monitoring up -d cadvisor
node-exporter prometheus`) scrapes the engine on `127.0.0.1:9930` and the API on
`127.0.0.1:8080` next to the recorder; open Prometheus on `127.0.0.1:9090`. Engine
metrics are per follow: orders, fills, rejects by reason, resyncs and repairs, leader to
follower lag and slippage. `curl -s localhost:9930/status` shows the same as JSON.

## Ports and variables

| Variable | Default | |
| --- | --- | --- |
| `COPY_WEB_PORT` | 8000 | Web app; also the API's `-public-url` and allowed origin |
| `COPY_API_PORT` | 8080 | API, directly (CORS allows only the web origin) |
| `COPY_ENGINE_PORT` | 9930 | Engine `/metrics` and `/status`, loopback only |
| `LEADERBOARD_PORT` | 8090 | `hl-leaderboard serve` |
| `LEADERBOARD_INTERVAL` | 60 | Seconds between collect and rank runs |
| `HL_SIM_LEADERS` | 5 | Leader accounts in hl-sim |
| `COPY_EXCHANGE_URL` | `http://hl-sim:3000` | Exchange API root for the API and the engine |
| `HL_COPY_MASTER_KEY` | development key | Seals agent keys |

## Kubernetes

The chart runs the same services when `copy.enabled` (on in `values-dev.yaml`): the
leaderboard as one pod (collect loop and server), the API and the engine as two
containers of one pod sharing a volume, and the web app behind a Service. Set
`copy.masterKey.existingSecret` outside development. After `helm install`,
`kubectl port-forward svc/<release>-hl-copy-web 8000:8080`.

## The testnet box

To copy leaders on books that follow Hyperliquid mainnet prices, run the services
against the anchored simulator of [the testnet box](testnet-box.md):
`make up-testnet`, then `COPY_EXCHANGE_URL=http://testnet-sim:3000 make up-copy`. The
leaderboard collector still reads `hl-sim`; point it at `testnet-sim` in the compose file
for a ranking of the box's leaders.
