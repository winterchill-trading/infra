# Service images and O3

`images/service/Dockerfile` takes `--build-arg O3=true`, which exports
`OCAMLPARAM='_,O3=1'` (flambda2 `-O3`) while the sibling pins are installed and while the
repo is built. Libraries that come with the base image (Core, Async, ...) keep their own
flags. Images carry the setting as the label `io.github.winterchill-trading.o3`.

The `service-images` workflow builds the hot binaries twice:

| Binary | `<commit12>` | Other tag | Why |
| --- | --- | --- | --- |
| hl-sim, binance-sim, bybit-sim | O3 | `-std` | order-book 0.6 to 0.85x, price-anchor 0.85x per event, bybit-client and hl-client frames 0.75 to 0.9x |
| market-maker | O3 | `-std` | mm-core quote 356 to 176 ns, idle tick 82 to 34 ns, requote 470 to 309 ns |
| market-recorder | default flags | `-o3` | 2 to 7% on normalize and event log, zstd unchanged, and binance-client is 4 to 9% slower at O3; not worth changing the system of record |
| market-replay | default flags | `-o3` | the raw reader that dominates replay is unchanged (1.43 M lines/s either way) |

## How it was measured

The `o3-compare` workflow runs each repo's own bench in the `bench` stage of the service
Dockerfile (the image build environment), default flags against `O3=true`, two
interleaved rounds on one `ubuntu-24.04` runner (amd64, 4 vCPUs) per repo, release
profile in both. Times below are the faster of the two rounds; words per call are exact.
Run of 2026-10-13, every sibling at its default branch.

### Benches (amd64, ns per call unless noted)

| Repo | Bench | Default | O3 | O3/default | Words default / O3 |
| --- | --- | ---: | ---: | ---: | --- |
| order-book | match 1 fill (IOC) | 95 | 57 | 0.60 | 27 / 22 |
| order-book | submit+cancel (existing level) | 208 | 171 | 0.82 | 40 / 40 |
| order-book | submit+cancel (new level) | 458 | 381 | 0.83 | 175 / 175 |
| order-book | sweep 10 levels + refill | 4,808 | 4,127 | 0.86 | 1,762 / 1,697 |
| order-book | mid | 13 | 3 | 0.20 | 5 / 3 |
| order-book | best_bid_or_null | 7 | 3 | 0.38 | 3 / 3 |
| price-anchor | per event, 0 / 50 / 500 clients | 8.7 / 11.8 / 41.2 us | 7.5 / 9.9 / 32.7 us | 0.86 / 0.85 / 0.79 | 2,641 / 2,465 (0 clients) |
| mm-core | quote flat | 356 | 176 | 0.49 | 51 / 51 |
| mm-core | quote+reconcile (keep all) | 1,424 | 1,045 | 0.73 | 442 / 355 |
| mm-core | strategy tick_u (no change) | 79 | 34 | 0.42 | 3 / 3 |
| mm-core | strategy on_book+tick (requote) | 470 | 309 | 0.66 | 242 / 227 |
| hl-client | trades frame | 1,550 | 1,240 | 0.80 | 41 / 41 |
| hl-client | l2 frame | 6,990 | 5,180 | 0.74 | 274 / 274 |
| hl-client | bbo only | 3,370 | 3,220 | 0.96 | 22 / 22 |
| bybit-client | trades frame | 1,748 | 1,533 | 0.88 | 54 / 52 |
| bybit-client | l2 frame | 2,392 | 2,084 | 0.87 | 528 / 484 |
| bybit-client | bbo frame | 792 | 717 | 0.91 | 73 / 45 |
| okx-feed | trades | 800 | 651 | 0.81 | 25 / 25 |
| okx-feed | l2 replay | 804,539 | 608,376 | 0.76 | 30,792 / 30,786 |
| binance-client | trades | 690 | 729 | 1.06 | 24 / 22 |
| binance-client | bbo | 627 | 655 | 1.04 | 21 / 19 |
| binance-client | depth (scan) | 15,791 | 17,256 | 1.09 | 3 / 3 |
| market-recorder | normalize (frames/s) | 1.85 M | 1.96 M | 0.94 | |
| market-recorder | raw write + zstd (frames/s) | 574 k | 580 k | 0.99 | |
| market-recorder | event log write (frames/s) | 3.90 M | 4.17 M | 0.94 | |
| market-recorder | merge files (frames/s) | 441 k | 454 k | 0.97 | |
| market-data | raw reader (lines/s) | 1.43 M | 1.43 M | 1.00 | 39.2 / 39.2 per line |
| parquet | Direct, no compression (rows/s) | 16.8 M | 18.5 M | 0.91 | 10.5 / 10.5 per row |
| parquet | add, zstd (rows/s) | 7.39 M | 7.46 M | 0.99 | 20.5 / 20.5 per row |

For throughput rows the ratio is time per item (inverse rate). The first market-recorder
default round (zstd 341 k frames/s) was an outlier and is not used.

The wave-7 benches measured locally (arm64, Apple M-series) for context: order-book fill
66 to 37 ns at O3, okx trades 0.48 to 0.46 us, parquet Direct 20.4 to 23.8 M rows/s.
Here on amd64 the order-book and okx gains are larger (0.60x and 0.81x) and parquet is
similar (16.8 to 18.5 M rows/s). binance-client is the only bench that gets slower; its
`Frame_scan` is already `[@zero_alloc]` and the extra inlining costs more than it saves.

### Images (service-images run 38329978629)

Build time is the whole `build.sh` step on a fresh runner (base image pull included);
size is the compressed image (sum of the layers).

| Binary | Commit | amd64 default | amd64 O3 | arm64 default | arm64 O3 |
| --- | --- | --- | --- | --- | --- |
| hl-sim | e34ed9e525d1 | 4m04s, 56 MiB | 3m38s, 57 MiB | 2m54s, 54 MiB | 3m00s, 55 MiB |
| binance-sim | 8d6ba7efa9ac | 3m08s, 56 MiB | 3m13s, 56 MiB | 2m33s, 54 MiB | 2m45s, 55 MiB |
| bybit-sim | 971041e7cfa1 | 4m11s, 56 MiB | 4m02s, 57 MiB | 3m17s, 55 MiB | 3m18s, 55 MiB |
| market-maker | 005eacf760db | 3m49s, 56 MiB | 4m42s, 57 MiB | 3m17s, 55 MiB | 3m50s, 56 MiB |
| market-recorder | bef36d8a4a55 | 4m26s, 75 MiB | 4m51s, 76 MiB | 3m48s, 72 MiB | 4m04s, 73 MiB |
| market-replay | 95a3f982ac10 | 3m28s, 55 MiB | 2m58s, 55 MiB | 2m37s, 53 MiB | 2m39s, 53 MiB |

O3 adds about 1 MiB per image and up to a minute of build time; runner noise is of the
same order. That run predates the tag switch, so its O3 images are tagged `-o3` for every
binary; the next run tags them as in the first table.

## Rerunning

```sh
gh workflow run o3-compare.yml                     # all benches, or -f repos="order-book mm-core"
gh workflow run service-images.yml -f o3=false     # skip the O3 builds
```

Each bench job prints its outputs to the run summary and uploads them as the
`bench-<repo>` artifact.
