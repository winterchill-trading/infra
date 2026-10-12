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

Each image is tagged `ghcr.io/winterchill-trading/<repo>:local`, runs as uid
10001, and has the binary as its entrypoint, so arguments go straight to it:

```sh
docker run --rm -p 3000:3000 ghcr.io/winterchill-trading/hl-sim:local -port 3000
curl -s localhost:3000/info -d '{"type":"meta"}'
```

## 3. Compose stack

```sh
make up     # simulators on 3000/3300/3400, a market maker per venue, MinIO
make ps
make logs
make down   # also drops the MinIO volume
```

MinIO's console is on http://localhost:9001 (`minioadmin` / `minioadmin`);
`minio-init` creates the `market-data` bucket. Upstream MinIO no longer
publishes images, so compose uses the community `pgsty/minio` build.

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
```

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
