# Test actions

Scripts that act on a running local stack (`make up`) and check that it
recovers. Each one prints what it did and exits non-zero on the first check
that fails. Run them from anywhere; they find the compose file themselves.

| Script | Action | Checks |
| --- | --- | --- |
| `orders.sh [venue] [seconds]` | runs a one-shot market maker (the market-maker e2e) inside the compose network against one simulator, under its own account | it placed orders; the recorder kept receiving that venue's frames |
| `recorder-restart.sh` | `docker compose restart market-recorder` (SIGTERM, then start) | `/healthz` is 200 again; the new process records; the minutes closed at shutdown end with disconnect lines; uploads continue |
| `network-cut.sh [sim] [seconds] [pause\|disconnect]` | cuts one simulator off: `pause` freezes it (connections stay open and silent), `disconnect` removes it from the network (name stops resolving) | the recorder reports the venue stale, then healthy again after the restore; frames flow again; the venue's market maker is still running |
| `upload-outage.sh [seconds]` | disconnects MinIO, so the upload command cannot resolve or reach it (what a DNS outage looks like to rclone) | uploads fail and pile up in `upload-pending.sexp`; recording goes on; the backlog drains after the restore |

Environment: `RECORDER_PORT` if the stack was started with a different host port.

## Results on the local stack (Rancher Desktop, 2 CPUs)

| Action | Outcome |
| --- | --- |
| `orders.sh hyperliquid 30` | 198 orders placed, 26 maker fills; recorder Hyperliquid frames 7964 -> 9371 |
| `orders.sh binance 20`, `orders.sh bybit 20` | 162 and 178 orders placed (Bybit: 2 rejected) |
| `recorder-restart.sh` | `restart` returned within 1 s (SIGTERM through tini, clean flush); healthy and recording 1 s later; 22 disconnect lines in the minutes closed at shutdown; uploads continued |
| `network-cut.sh hl-sim 45 pause` | stale after 29 s (the 30 s health window); healthy 1 s after unpause, the frozen connections resumed without a reconnect |
| `network-cut.sh binance-sim 45 disconnect` | stale after 29 s; healthy 8 s after reconnecting the simulator; `mm-binance` kept running, no restarts |
| `upload-outage.sh 240` | recording unaffected; 89 files pending after 240 s, only 5 failed rclone runs (each run retries for about 150 s first); backlog drained 4 s after the restore |

What the numbers mean for operations is in
[docs/troubleshooting.md](../docs/troubleshooting.md).
