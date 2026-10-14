# Running locally on macOS (Rancher Desktop)

## 1. Rancher Desktop

Install Rancher Desktop and open **Preferences**:

- **Container engine.** Pick **dockerd (moby)**. With moby, images built by
  `docker buildx build --load` are visible to the bundled k3s cluster without
  a registry, which is what `values-dev.yaml` (`imagePullPolicy:
  IfNotPresent`, tag `local`) and the Tiltfile rely on. With
  **containerd + nerdctl** it works too, but images must be built into the
  `k8s.io` namespace: `nerdctl --namespace k8s.io build ...`, and
  `build.sh` (which calls `docker buildx`) does not do that for you.
- **Kubernetes.** Enable it; any recent version works.
- **Virtual machine.** The OxCaml compiler build needs memory: give the VM at
  least 4 CPUs and 8 GB if you build the base image locally. With 6 GB and
  Kubernetes enabled the compiler build ran the VM out of memory (no swap by
  default): the kernel killed cluster pods, the build failed with `failed to
  solve: Unavailable: error reading from server: EOF`, and the host's
  `~/.rd/docker.sock` forwarder stopped answering. Either raise the memory or
  add swap on the VM's data disk before building (not on `/`, which is
  tmpfs):

  ```sh
  rdctl shell sudo sh -c 'fallocate -l 6G /mnt/data/swap && chmod 600 /mnt/data/swap \
    && mkswap /mnt/data/swap && swapon /mnt/data/swap'
  ```

  If the host socket is dead while `rdctl shell docker info` works, forward
  it over Lima's ssh until Rancher Desktop is restarted:

  ```sh
  ssh -F ~/Library/Application\ Support/rancher-desktop/lima/0/ssh.config \
    -fnNT -L ~/.rd/fwd.sock:/var/run/docker.sock lima-0
  export DOCKER_HOST=unix://$HOME/.rd/fwd.sock
  ```

The CLIs (`docker`, `nerdctl`, `kubectl`, `helm`) live in `~/.rd/bin`; put it
on `PATH`. Then:

```sh
kubectl config use-context rancher-desktop
kubectl get nodes
```

## 2. Images

Pull the base image from GHCR, or build it for the host architecture
(40-90 minutes, most of it the OxCaml compiler):

```sh
docker pull ghcr.io/winterchill-trading/oxcaml-base:latest
# or
make base
```

Service images, one per binary:

```sh
images/service/build.sh hl-sim hl-sim                 # clones main from GitHub
SRC=../hl-sim images/service/build.sh hl-sim hl-sim   # from a local checkout
images/service/build.sh market-recorder market-recorder --build-arg RUNTIME_PACKAGES=rclone
```

`build.sh` first resolves the repo's commit (`REF`, default `main`, or the
`SRC` checkout's `HEAD`, suffixed `-dirty` when it has changes) and every
sibling pin in the repo's `ci.yml` to its current commit, then pins the
siblings at exactly those commits. The commits end up as labels:

```sh
docker image inspect ghcr.io/winterchill-trading/hl-sim:local --format \
  '{{index .Config.Labels "org.opencontainers.image.revision"}} {{index .Config.Labels "io.github.winterchill-trading.pins"}}'
```

Each image is tagged `ghcr.io/winterchill-trading/<repo>:local`, runs as uid
10001, and has the binary as its entrypoint, so arguments go straight to it:

```sh
docker run --rm -p 3000:3000 ghcr.io/winterchill-trading/hl-sim:local -port 3000
curl -s localhost:3000/info -d '{"type":"meta"}'
```

## 3. Compose stack

```sh
make up     # simulators on 3000/3300/3400, a market maker per venue, MinIO
make ps     # compose ps, then each service's commit and sibling pins
make logs
make down   # stops and removes the containers; volumes and data stay
```

`make down` keeps every named volume (MinIO, the recorder, the copy-trading data)
and the Postgres directory, so the next `make up` starts where the last one stopped.
`make reset-data CONFIRM=yes` is the clean slate: it stops the stack and deletes all
of them (see [Databases](#databases)).

Host ports default to the in-container ones and can be moved when something
else already listens there: `HL_SIM_PORT`, `BINANCE_SIM_PORT`,
`BYBIT_SIM_PORT`, `MINIO_PORT`, `MINIO_CONSOLE_PORT`, `RECORDER_PORT`, e.g.
`HL_SIM_PORT=13000 make up`. The recorder answers on
`localhost:9100/healthz` and `/metrics`; closed minute files appear in the
bucket under `raw/<venue>/<stream>/<symbol>/...` within a minute of `up`.

MinIO's console is on http://localhost:9001 (`minioadmin` / `minioadmin`);
`minio-init` creates the `market-data` bucket. Upstream MinIO no longer
publishes images, so compose uses the community `pgsty/minio` build.

### Databases

One PostgreSQL 18 server (`postgres:18-alpine`) holds the databases of the services
that keep state in SQL:

| Database | Owner role | Password variable (development default) | Used by |
| --- | --- | --- | --- |
| `neobank` | `neobank` | `NEOBANK_DB_PASSWORD` (`neobank-dev`) | `neobank-api` (profile `neobank`, [neobank.md](neobank.md)) |
| `hl_copy` | `hl_copy` | `HL_COPY_DB_PASSWORD` (`hl-copy-dev`) | `hl-copy-api` (profile `copy`): follows, sealed agent keys, approvals |

The superuser is `postgres` / `POSTGRES_PASSWORD` (default `postgres`). The defaults
are for a development machine only; export your own values before the first start
for anything else.

```sh
make up-db                      # postgres alone (profile db); make up-copy starts it too
psql -h 127.0.0.1 -p 5432 -U hl_copy hl_copy          # password hl-copy-dev
psql -h 127.0.0.1 -p 5432 -U neobank neobank          # password neobank-dev
docker compose -f compose/docker-compose.yml exec postgres psql -U postgres   # no local psql
```

The port is published on 127.0.0.1 only; `PG_PORT` moves it when something else
already listens on 5432 (`PG_PORT=5433 make up-db`). Inside the compose network the
services reach it as `postgres:5432` through `DATABASE_URL`, which ends in
`?sslmode=disable`: pg-async requires TLS otherwise, and this server has none.
`hl-copy-api` and `neobank-api` wait for its `pg_isready` healthcheck; their images
carry `libpq5` (`RUNTIME_PACKAGES`), the build stage has `libpq-dev`.

**Where the data lives.** A bind mount outside the repo,
`$WINTERCHILL_DATA_DIR/postgres`, default `~/.winterchill/postgres` (Postgres 18
writes its cluster to `18/docker` inside it). It survives `make down`, container
recreation and image upgrades. To keep it elsewhere, set the variable for every
make or compose command, e.g. in your shell profile:

```sh
export WINTERCHILL_DATA_DIR=/Volumes/data/winterchill
```

**Roles and databases** are created by `compose/postgres/initdb.d/10-databases.sh`,
which the image runs once, on an empty directory. Changing a password variable later
does not change an existing role: `ALTER ROLE ... PASSWORD ...`, or start over.

**Starting over.** `make reset-data CONFIRM=yes` stops the stack, removes its named
volumes (MinIO, recorder, leaderboard, `copy-data`, `copy-journals`) and deletes the
Postgres directory; without `CONFIRM=yes` it only prints what it would delete. The
directory is deleted from a throwaway container because on a Linux host its files
belong to the container's postgres user (uid 70).

In the cluster the chart runs the same server as a StatefulSet when `postgres.enabled`
(on in `values-dev.yaml`), with a PersistentVolumeClaim (`postgres.persistence.size`,
5Gi) and the same init script from a ConfigMap. Passwords come from
`postgres.auth.*` or `postgres.auth.existingSecret` (keys `POSTGRES_PASSWORD`,
`NEOBANK_DB_PASSWORD`, `HL_COPY_DB_PASSWORD`). The claim `data-<release>-postgres-0`
outlives `helm uninstall`; delete it by hand to start over.

### Neobank demo

`make up-neobank` runs neobank-api and neobank-web on the `neobank` database; see
[neobank.md](neobank.md).

### proctopus instead of compose: tried, not adopted

proctopus (a terminal UI that runs and restarts several processes, with a log
pane per process and `-log DIR` to tee output to files) was tried on 2026-10-12
as a way to run the three simulators, the market makers and the recorder as
native processes.

- macOS: does not build. `opam install proctopus` on the `5.2.0+ox` switch fails in
  its dependency `mmap` (`mremap`, `off64_t` and `MADV_*` are Linux-only), and
  `procfs` reads `/proc`. The opam files do not mark either as Linux-only, so opam
  only finds out at compile time.
- Linux: builds and runs. The manual `proctopus` workflow
  (`gh workflow run proctopus.yml`) installs it with the ox-setup action on
  `ubuntu-latest` (24 minutes cold, 53 packages, Bonsai and its web
  dependencies included) and keeps it running under a pseudo-terminal with three
  commands for 15 seconds.

Compose stays the local stack: it runs on macOS through Rancher Desktop, and the
stack needs MinIO, the image pins and the container network anyway. proctopus is
worth another look for a Linux workstation running the binaries straight from
`dune build` (no image rebuilds): one `name:command` argument per service, e.g.
`proctopus 'sims/hl:hl-sim -port 3000' 'sims/binance:binance-sim -port 3300' ...`.

### Day close and data-quality check

`make up-day-close` builds the `market-data` image with the DuckDB CLI
(`DUCKDB_VERSION`, default 1.5.6) and starts the `day-close` service under the
compose profile of the same name. Every `DAY_CLOSE_INTERVAL` seconds (default
3600) it runs `market-data day-close` on the recorder volume, then
`market-data check -max-gap $DAY_CLOSE_MAX_GAP` (default `1m`) over the
parquet tables. The result is in its log:

```sh
docker compose -f compose/docker-compose.yml logs day-close | grep -E 'FAIL|day-close check'
```

A failed check prints a `FAIL <check> <table> <violations>` line per failing
assertion, the largest recv_ts gaps, then `day-close check FAILED`; the loop
keeps running. The check covers every day in `parquet/`, so a gap from a stopped
stack stays a violation for as long as that day's tables are on the volume; raise
`DAY_CLOSE_MAX_GAP` above it or delete the volumes (`make reset-data CONFIRM=yes`).

### Socket, FD and RSS collectors

`make up-monitoring` adds three containers under the compose profile
`monitoring` (`make down` removes them too). All three listen on loopback only, as
does the MinIO console; cadvisor runs unprivileged with `SYS_ADMIN` and `SYS_PTRACE`:

| Container | Port | What |
| --- | --- | --- |
| `cadvisor` | `CADVISOR_PORT` (8088) | per container: `container_sockets`, `container_file_descriptors`, `container_memory_rss`, `container_threads`, TCP connections by state (`container_network_tcp_usage_total`) |
| `node-exporter` | `NODE_EXPORTER_PORT` (9101), host network | the Docker VM: `node_sockstat_TCP_inuse`, `node_netstat_Tcp_RetransSegs`, `node_tcp_connection_states`, `node_filefd_allocated` |
| `prometheus` | `PROMETHEUS_PORT` (9090) | scrapes both and the recorder every 5 s, keeps a day |

```sh
curl -s localhost:8088/metrics | grep -E '^container_(sockets|file_descriptors|memory_rss)\{.*market-recorder'
open 'http://localhost:9090/query?g0.expr=container_sockets'
```

In the cluster the chart runs node-exporter as a DaemonSet when `monitoring.enabled`
is set (off by default, on in the dev profile), with only the `sockstat`, `filefd`,
`netstat`, `meminfo` and `cpu` collectors;
per-container sockets, FDs and RSS come from the kubelet's built-in cAdvisor, which
k3s serves without extra pods:

```sh
kubectl get --raw /api/v1/nodes/$(kubectl get nodes -o name | head -1 | cut -d/ -f2)/proxy/metrics/cadvisor \
  | grep -E '^container_(sockets|file_descriptors|memory_rss)\{.*recorder'
```

## 4. Helm on Rancher Desktop

The dev profile runs the simulators in the cluster and points the recorders
at them. Uploads go to the MinIO started by compose, reached from pods as
`host.rancher-desktop.internal:9000`.

```sh
make up                     # for MinIO, or run only: docker compose -f compose/docker-compose.yml up -d minio minio-init
helm install winterchill charts/winterchill -f charts/winterchill/values-dev.yaml
kubectl get pods -l app.kubernetes.io/instance=winterchill
kubectl port-forward svc/winterchill-recorder-binance 9100 &
curl localhost:9100/healthz
```

Upgrades after changing values: `helm upgrade winterchill charts/winterchill
-f charts/winterchill/values-dev.yaml`. Remove with `helm uninstall
winterchill` (the PVCs stay; delete them with `kubectl delete pvc -l
app.kubernetes.io/instance=winterchill`).

Run a day close by hand instead of waiting for the schedule:

```sh
kubectl create job --from=cronjob/winterchill-day-close-binance day-close-now
kubectl logs -f job/day-close-now -c day-close
kubectl logs -f job/day-close-now -c check
```

The `check` container (`dayClose.check.enabled`, on by default) runs
`market-data check -max-gap <dayClose.check.maxGap>` beside the upload once the
close is done. Violations fail the Job (the upload still runs), so
`kubectl get jobs -l app.kubernetes.io/name=day-close` shows it, and with
kube-state-metrics installed `kube_job_status_failed{job_name=~".*day-close.*"} > 0`
is the alert. The image needs DuckDB: build it with `make build-day-close` (or
`service-images.yml`, which adds `DUCKDB_VERSION` for market-data).

`charts/rendered-example.yaml` is `helm template` of the dev profile, kept in
the repo for review; `make chart` regenerates it and CI fails if it is stale.

## 5. Tilt

`brew install tilt`, check out the service repos next to `infra`
(`../hl-sim`, `../market-recorder`, ...), then from `infra/`:

```sh
tilt up
```

The `Tiltfile` builds each image from the local checkout with
`images/service/build.sh` (`SRC=../<repo>`), installs the chart with the dev
profile, and port-forwards the simulators. Saving a file under a repo's
`bin/` or `lib/` rebuilds that image and rolls its pods. A rebuild reuses the
cached opam layer, so only the `dune build` step runs again.
