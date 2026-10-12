# AWS target topology

Status: design notes. Nothing here is automated yet; Terraform (or another
IaC tool) is out of scope for this repo for now. The Helm chart in
`charts/winterchill` is what runs on the clusters described below.

## Regions and clusters

Collectors run close to the venues' matching engines, so receive timestamps
carry as little network jitter as possible:

| Region | Venues | Why |
| --- | --- | --- |
| `ap-northeast-1` (Tokyo) | Binance, Hyperliquid | Binance futures and the Hyperliquid API front ends are served from Tokyo |
| `ap-southeast-1` (Singapore) | Bybit | Bybit's matching engine and API are in Singapore |

Each region runs one small **k3s** cluster on EC2:

- One server node (`k3s server`, embedded etcd off, SQLite datastore) that
  also runs workloads. Recorders are light; a `c7g.large` (Graviton, arm64)
  holds several venues. The base and service images are multi-arch, so arm64
  and amd64 nodes both work.
- An encrypted gp3 EBS root plus the k3s `local-path` provisioner for the
  recorder buffer PVCs. The buffer only holds files until the upload succeeds
  (`deleteAfterUpload: true`) plus the normalized event logs that
  `day-close` reads; 20 GiB per venue is ample.
- Optional second node per region later, running a second copy of each
  recorder for redundancy (two independent raw streams; deduplicate
  downstream by venue sequence numbers).
- Install: `curl -sfL https://get.k3s.io | sh -`, then `helm install
  winterchill charts/winterchill -f values-<region>.yaml`, where the region
  file lists only that region's venues under `recorder.venues`.
- Images come from GHCR (`ghcr.io/winterchill-trading/*`); the packages are
  public, so no pull secret is needed.
- Access: SSM Session Manager, no inbound SSH; the security group allows no
  inbound traffic at all (recorders only dial out). Metrics and health are
  read through `kubectl port-forward` over SSM, or scraped by an in-cluster
  Prometheus/agent that remote-writes elsewhere.
- Time: chrony with the Amazon Time Sync Service (`169.254.169.123`); the raw
  files' receive timestamps are only as good as the host clock.

## S3 layout

One bucket, e.g. `winterchill-market-data`, in `ap-northeast-1`. Singapore
uploads cross-region (small: compressed minute files). The keys mirror the
recorder's data directory one to one, because the upload command is
`rclone copyto {file} s3:<bucket>/{rel}`:

```
s3://winterchill-market-data/
  raw/<venue>/<stream>/<symbol>/<YYYY>/<MM>/<DD>/<HH>-<MM>.ndjson.zst   # recorder, every minute
  <venue>/<symbol>/parquet/<table>/<YYYY-MM-DD>.parquet                # day-close, daily
```

- `raw/` is the archive of record: venue frames exactly as received, with
  receive timestamps, Tardis-style. A day of one stream is the concatenation
  of its minute files in name order.
- The parquet tables (`trades`, `bbo`, `l2`, `funding`, `candles`) are
  derived and can be rebuilt from `raw/` at any time.
- Set `s3.prefix` to put a cluster under its own prefix (e.g. a staging
  cluster) without changing the layout below it.

### Lifecycle

- `raw/`: transition to **S3 Glacier Instant Retrieval** after 90 days (or
  Glacier Flexible Retrieval if replays of old data are rare; restores then
  take hours). No expiry.
- Parquet prefixes: stay in Standard (they are what queries hit); optionally
  Standard-IA after 180 days.
- Abort incomplete multipart uploads after 7 days.
- Versioning on, with noncurrent versions expiring after 30 days, so a bad
  re-upload or `day-close -force` can be undone.

```json
{
  "Rules": [
    {
      "ID": "raw-to-glacier",
      "Filter": { "Prefix": "raw/" },
      "Status": "Enabled",
      "Transitions": [{ "Days": 90, "StorageClass": "GLACIER_IR" }],
      "NoncurrentVersionExpiration": { "NoncurrentDays": 30 },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
```

## IAM

The recorders and the day-close job upload with the **EC2 instance role**
(`s3.useInstanceRole: true`, the chart default; rclone picks the credentials
up from the instance metadata service, so no Secret exists in the cluster).
Require IMDSv2 with a hop limit of 2 so pods can reach it.

Uploader role policy, write-only (no delete, no read of other prefixes):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:AbortMultipartUpload"],
      "Resource": [
        "arn:aws:s3:::winterchill-market-data/raw/*",
        "arn:aws:s3:::winterchill-market-data/*/parquet/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::winterchill-market-data"
    }
  ]
}
```

`ListBucket` is there because `rclone copy` (day-close upload) lists the
destination to skip unchanged files. The recorder's `rclone copyto` would
work without it; pass `--s3-no-check-bucket` if the bucket is pre-created
(it is). Analysts get a separate read-only role.

## Querying

The parquet tables are directly queryable from S3:

- **DuckDB** (laptop or a notebook box in the region), with the `httpfs`
  extension and credentials from the environment:

  ```sql
  INSTALL httpfs; LOAD httpfs;
  CREATE SECRET (TYPE s3, PROVIDER credential_chain, REGION 'ap-northeast-1');
  SELECT venue, symbol, count(*) AS n, sum(size::DOUBLE) AS volume
  FROM read_parquet('s3://winterchill-market-data/*/*/parquet/trades/2026-10-*.parquet')
  GROUP BY ALL ORDER BY ALL;
  ```

  `market-data views` prints the per-table views for a local mirror; the same
  statements work with `s3://` globs.
- **Athena**: one Glue table per parquet table, partitioned by
  `venue`/`symbol` using partition projection over the key layout
  (`<venue>/<symbol>/parquet/trades/`), with the date taken from the file
  name. Note that prices and sizes are `DECIMAL(18,8)` and timestamps are
  `TIMESTAMP_NS` (`isAdjustedToUTC=false`); Athena (Trino) reads nanosecond
  timestamps as `timestamp(9)` only through the Iceberg/Hive v3 path, so
  either query through DuckDB or cast in a view.

Raw files stay as zstd ndjson; replaying them goes through
`market-data` (`Replay_feed`) after downloading the needed minutes, or
`zstd -dc` for ad hoc inspection.

## Operations

- Alerting: page when `/healthz` is 503 for more than a few minutes, when
  `market_recorder_upload_pending` keeps growing, or when the day-close job
  fails.
- Disk: the buffer volume fills only if uploads stop; watch PVC usage and
  `upload_pending` together. Normalized event logs are not uploaded and stay
  on the volume; prune `norm/` days older than a week after day-close has
  converted them.
- Deploys: `helm upgrade`; recorders use the `Recreate` strategy, so a
  deploy is a gap of a few seconds in that venue's stream, marked by the
  disconnect line the recorder writes at shutdown. Run a second replica on a
  second node before relying on gap-free data.
