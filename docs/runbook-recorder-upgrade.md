# Runbook: upgrading the recorder Helm release

For a new recorder image, a chart change or new values. Each venue is its own
Deployment (`<release>-recorder-<venue>`) with the `Recreate` strategy and its
own PVC, so an upgrade stops a venue's recorder before the new one starts:
expect a gap of a few seconds per venue, marked in every raw stream by the
empty (disconnect) line the old process writes on `SIGTERM`.

The commands assume release `winterchill`, values file `values-<region>.yaml`
and the recorder port 9100; adjust for the region.

## 1. Before

1. Know what runs now and what will run:

   ```sh
   helm history winterchill --max 5
   kubectl get deploy -l app.kubernetes.io/name=market-recorder \
     -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
   ```

   The new image tag is a commit (`ghcr.io/winterchill-trading/market-recorder:<commit12>`,
   see the `service-images` workflow). Check it exists for the node's architecture and
   read the commits it was built from:

   ```sh
   docker buildx imagetools inspect ghcr.io/winterchill-trading/market-recorder:<commit12>
   docker buildx imagetools inspect ghcr.io/winterchill-trading/market-recorder:<commit12> \
     --format '{{ json (index .Image "linux/arm64").Config.Labels }}'
   ```

2. Check the new binary accepts the config the chart will render (a config the binary
   rejects keeps the pod in `CrashLoopBackOff`):

   ```sh
   helm template winterchill charts/winterchill -f values-<region>.yaml \
     --show-only templates/recorder-configmap.yaml \
     | yq 'select(.metadata.name == "winterchill-recorder-binance") | .data["recorder.sexp"]' > /tmp/recorder.sexp
   docker run --rm -v /tmp/recorder.sexp:/c.sexp:ro \
     ghcr.io/winterchill-trading/market-recorder:<commit12> check-config -config /c.sexp
   ```

3. Review the change against the live objects:

   ```sh
   helm template winterchill charts/winterchill -f values-<region>.yaml \
     --set recorder.image.tag=<commit12> | kubectl diff -f -
   ```

   Only the recorder Deployments (image, `checksum/config` annotation) and the
   ConfigMaps should differ. A PVC change cannot be applied in place.

4. Health and backlog are normal (one port-forward per venue):

   ```sh
   kubectl port-forward deploy/winterchill-recorder-binance 9100 &
   curl -s localhost:9100/healthz                     # 200 ok
   curl -s localhost:9100/metrics | grep -E 'upload_(pending|failures_total)'
   ```

   Do not upgrade while `market_recorder_upload_pending` is growing: fix uploads
   first (see [troubleshooting](troubleshooting.md)). Pending files survive the restart
   (`upload-pending.sexp` is on the PVC), but a broken upload path is easier to
   diagnose on the old version.

## 2. When

- Not between 00:00 and 00:30 UTC: the day rolls, and the `day-close` CronJob
  (00:20) reads the event logs the recorder is writing.
- Early in a minute (seconds 5 to 40). Shutdown compresses the open minute and the new
  process appends a second zstd frame to that same `.zst` when it starts within the
  minute, which is valid but means the minute was uploaded twice; starting after the
  minute boundary keeps the gap in one file.

## 3. Upgrade

Optionally canary one venue first, by hand, then let Helm catch up:

```sh
kubectl set image deploy/winterchill-recorder-binance \
  recorder=ghcr.io/winterchill-trading/market-recorder:<commit12>
kubectl rollout status deploy/winterchill-recorder-binance --timeout 3m
# verify as in section 4, then:
```

Upgrade the release (the canary is already at the new image and does not restart again):

```sh
helm upgrade winterchill charts/winterchill -f values-<region>.yaml \
  --set recorder.image.tag=<commit12> --wait --timeout 5m
```

Prefer committing the tag to `values-<region>.yaml` over `--set`, so the next upgrade
does not silently roll back.

## 4. Verify

```sh
kubectl get pods -l app.kubernetes.io/name=market-recorder      # all Running, 0 restarts
kubectl logs deploy/winterchill-recorder-binance | head -20      # startup: queued uploads, connects
```

For each venue, within a minute:

- `/healthz` answers `200 ok` (every stream had a frame in the last 30 s).
- `market_recorder_frames_total` grows between two scrapes.
- `market_recorder_uploads_total` increases after the next minute boundary and
  `market_recorder_upload_pending` returns to its usual 0 to 2.
- The bucket has a new object for the current minute:
  `aws s3 ls s3://winterchill-market-data/raw/binance/trades/BTCUSDT/$(date -u +%Y/%m/%d)/ | tail -2`.

## 5. Roll back

```sh
helm history winterchill --max 5
helm rollback winterchill <previous revision> --wait --timeout 5m
```

Files the new version wrote stay on the PVC and in S3. Check the recorder's changelog
for raw or event-log format changes before rolling back across one: the old binary
appends to today's event log and recompresses crash leftovers on startup. Rollback
restores the ConfigMaps of that revision too.
