# Troubleshooting

Notes for the recorders, in compose and on the clusters. The test actions in
[`test-actions/`](../test-actions/README.md) reproduce most of these failures on the
local stack.

## A stream is stale

`/healthz` answers `503` with the stale `(venue stream symbol)` triples;
`market_recorder_last_frame_age_seconds` shows how long each has been quiet. The venue
clients reconnect and resubscribe on their own, so a stream that stays stale for more
than a minute or two usually means the connection is open but silent (a black hole),
or every reconnect fails (DNS, TLS, the venue rejecting the subscription). Logs tell
the two apart: reconnect attempts are logged by the venue client.

## Looking at the sockets: `ss -tipn`

`ss -tipn` prints every TCP socket of a network namespace with its kernel state: RTT,
congestion window, retransmits, bytes acked and received, and the time since the last
send and receive. The runtime image has no `ss` (it carries only what the binary needs),
so run it from a debug container that shares the recorder's network namespace.

Compose:

```sh
docker run --rm --network container:winterchill-market-recorder-1 \
  nicolaka/netshoot:v0.14 ss -tipn
```

Kubernetes (ephemeral container in the pod):

```sh
kubectl debug -it deploy/winterchill-recorder-binance --image=nicolaka/netshoot:v0.14 \
  --target=recorder -- ss -tipn
```

On the node, without pulling an image: `nsenter -t <recorder pid> -n ss -tipn`, with the
pid from `crictl inspect` / `ps`.

What to read, per venue connection (`ss -tipn dst <venue ip>` narrows it):

| Field | Healthy | Suspicious |
| --- | --- | --- |
| `Recv-Q` | near 0 | growing: the recorder is not reading fast enough (CPU, a blocked Async cycle) |
| `Send-Q` | 0 | non-zero and stuck: the peer stopped acking, the path is dead |
| `lastrcv` (ms) | below the feed's message interval | growing past 30000 while the socket stays `ESTAB`: a black hole; the recorder's own staleness check fires at 30 s |
| `rtt:a/b` | stable, close to the region's latency to the venue | jumps: path change or congestion |
| `retrans:a/b`, `lost` | 0 / small | climbing: packet loss on the path |
| `cwnd` | stable | collapsing to 1-2 with retransmits: loss |

A socket in `ESTAB` with growing `lastrcv`, no `Send-Q` and no retransmits is a feed
the venue stopped sending on without closing; nothing in TCP will notice, so only the
recorder's staleness check and the client's ping timeouts end it.

## Uploads during a DNS outage

What resolves names, and when:

- **Venue feeds** resolve the venue host when they connect or reconnect. Established
  websockets keep streaming through a DNS outage; a feed that drops during one cannot
  reconnect until names resolve again, and shows up as stale on `/healthz`.
- **Uploads**: every closed minute runs the upload command, and every `rclone` run
  resolves the S3 endpoint (`s3.<region>.amazonaws.com`, or `minio` in compose) afresh.
  In the cluster the path is pod, CoreDNS, node resolver, VPC resolver.

Measured on the compose stack by taking MinIO off the network for 240 s
(`test-actions/upload-outage.sh`, the lookup fails with `no such host`):

- Recording is unaffected: `/healthz` stayed 200 throughout.
- `rclone` does not fail fast. With its default retries (3 attempts of 10 low-level
  retries each) one `copyto` took 148 s to exit non-zero (`lsd`: 47 s). The recorder
  runs at most 4 uploads at a time, so all four slots sit in retrying `rclone` runs:
  `market_recorder_upload_failures_total` stayed flat for the first two and a half
  minutes while `market_recorder_upload_pending` climbed (89 files after 240 s for the
  compose config, three venues and 22 streams, about 22 files a minute).
- Every pending file is listed in `<data_dir>/upload-pending.sexp`, which the recorder
  rewrites on each change; a restart during the outage loses nothing.
- When MinIO came back the backlog drained in 4 s.

Consequences:

- Alert on `upload_pending` growing, not on `upload_failures_total`, which lags by the
  length of an `rclone` run.
- After a long outage, drain can wait for the recorder's retry backoff, which doubles
  from 1 s up to 5 minutes while runs keep failing.
- The buffer volume grows by the compressed size of every minute file for as long as
  the outage lasts; compare `market_recorder_upload_pending` with the PVC usage.
- To make failures visible within seconds and leave retrying to the recorder, give
  `rclone` `--retries 1 --low-level-retries 2` (it then fails in under a second on a
  failed lookup), and `--contimeout 10s --timeout 60s` so a black-holed endpoint
  cannot hold a slot for long. The chart and compose keep rclone's defaults for now.
- A node-local DNS cache (or k3s CoreDNS `cache`) does not help uploads much: the
  S3 endpoint's records have short TTLs, so a long outage outlives the cache.

To check by hand from the recorder:

```sh
docker exec winterchill-market-recorder-1 getent hosts minio
kubectl exec deploy/winterchill-recorder-binance -- getent hosts s3.ap-northeast-1.amazonaws.com
kubectl exec deploy/winterchill-recorder-binance -- sh -c 'grep -c zst /var/lib/market-recorder/upload-pending.sexp'
```
