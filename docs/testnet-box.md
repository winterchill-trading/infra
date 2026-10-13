# Hyperliquid testnet in a box

`make up-testnet` starts a local stand-in for Hyperliquid testnet: an hl-sim whose order
books follow Hyperliquid mainnet's public feed, leader accounts trading on it, a market
maker per coin and a recorder recording the result, with the monitoring collectors. It
needs no keys and sends nothing to Hyperliquid: the simulator only reads the public
websocket (`l2Book`, `trades`, `activeAssetCtx`) of BTC, ETH and SOL.

```sh
make up-testnet                         # builds hl-sim, hl-mm, market-recorder images first
curl -s localhost:3600/info -d '{"type":"allMids"}'
curl -s localhost:3600/info -d '{"type":"l2Book","coin":"BTC"}'
docker compose -f compose/docker-compose.yml logs -f testnet-sim   # anchor status every 10 s
make down
```

| Service | What it runs |
| --- | --- |
| `testnet-sim` | `hl-sim -anchor hyperliquid:BTC -anchor hyperliquid:ETH -anchor hyperliquid:SOL -leaders 5`, published on `TESTNET_SIM_PORT` (3600) |
| `testnet-mm-btc`, `testnet-mm-eth` | `hl-mm` quoting BTC and ETH around the anchored books, one account each (`0x...b1`, `0x...b2`) |
| `testnet-recorder` | `market-recorder` with `compose/recorder-testnet.sexp`: trades, BBO and L2 of the three coins, kept on the `testnet-recorder-data` volume (no upload); `/metrics` on `TESTNET_RECORDER_PORT` (9110) |
| `cadvisor`, `node-exporter`, `prometheus` | The `monitoring` profile (see [local.md](local.md)); Prometheus also scrapes the box's recorder |

Point a client at `http://localhost:3600` (websocket `ws://localhost:3600/ws`) wherever it
would take testnet's API root. Every address is credited the simulator's initial balance
on first use, so there is no faucet step. The copy-trading services can run against the
box by setting their API root to `http://testnet-sim:3000` (see
[copytrading.md](copytrading.md)).

## What the box reproduces

The authoritative, endpoint-by-endpoint comparison is
[specs/research/hl-sim-parity.md](https://github.com/winterchill-trading/specs/blob/main/research/hl-sim-parity.md);
this is the short version for someone deciding whether a test needs real testnet.

Same as Hyperliquid:

- Paths and transport: `POST /info`, `POST /exchange`, the websocket on `/ws`,
  `ping`/`pong`.
- Prices and books: anchored mid, top levels and trades of mainnet BTC, ETH and SOL
  (five reference levels a side resting in the book, `-anchor-levels`), mark price from
  the reference, funding from the reference's rate.
- Order rules: tick (5 significant figures, `6 - szDecimals` decimals), size step, the
  $10 minimum, ALO crossing and IOC no-match errors, `cancel` and `cancelByCloid`
  responses, `openOrders` fields.
- Margin: initial margin per `maxLeverage`, maintenance at half of it, hourly funding,
  liquidation trigger at the mark.
- Copy-trading flow (hl-sim after the parity snapshot): `approveAgent` and
  `approveBuilderFee` signed by the user, agent-signed orders acting for the user,
  `userFillsByTime`, `maxBuilderFee`, `extraAgents`, the `leaderboard` info request and
  user subscriptions for any address.

Not reproduced (a test that depends on these needs testnet):

- Signature and nonce checks, unless the simulator runs with `-strict-signatures`
  (the box does not: requests act as their `X-Address`).
- Rate limits of every kind (IP weight, address budget, open order cap, websocket
  limits including the 10 unique users per IP), so back-off paths are not exercised.
- Self-trade prevention: the simulator cancels the taker's remainder where Hyperliquid
  cancels the resting order.
- Fees: 3.5 bp taker and 1 bp maker, a better tier than Hyperliquid's base 4.5 and 1.5.
- Trigger orders, `scheduleCancel`, `batchModify`, `updateLeverage`, `orderStatus`,
  push account channels (`clearinghouseState`, `userEvents`), the websocket idle timeout
  and server-side disconnects.
- Oracle separate from the mark, premium-based funding and book liquidations.
- Mainnet's book depth beyond the anchored levels and its `l2Book` cadence: the
  simulator pushes book changes every 50 ms, about ten times mainnet's rate.
