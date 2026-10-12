# Runtime tuning: OCAMLRUNPARAM and memtrace

Notes for the services on the `5.2.0+ox` runtime (OCaml 5 runtime, flambda2), measured
on the market recorder, the long-running service whose memory matters most.

## OCAMLRUNPARAM by peak RSS and CPU time

`scripts/gc-compare.sh [SECONDS] [SETTING...]` starts one recorder per setting, all at
the same time, against the simulators of the running compose stack (so every run sees
the same feed), each in its own container with a private data directory and no upload.
After SECONDS it reads, from `/proc` of the service process, peak RSS (`VmHWM`),
current RSS and user+system CPU time, and the recorder's total frame count as a check
that the runs did the same work.

```sh
make up
scripts/gc-compare.sh 600 o=80 o=120 o=200 o=400
```

`o` is the major GC's space overhead (percent of live data allowed as garbage before
a cycle completes; default 120 on OCaml 5). `s` is the minor heap size in words
(default 256k).

Results on Rancher Desktop (2 vCPU, arm64), recording the compose config (3 venues,
2 symbols each, 22 streams):

Run 1, 300 s:

| Setting | Peak RSS (MB) | RSS at end (MB) | CPU (s) | Frames |
| --- | --- | --- | --- | --- |
| `o=60` | 80.7 | 69.0 | 6.0 | 42782 |
| `o=120` (default) | 81.6 | 74.5 | 5.7 | 42771 |
| `o=200` | 92.7 | 85.5 | 5.3 | 42768 |
| `s=1M` | 83.3 | 73.1 | 5.7 | 42743 |

Run 2, 600 s:

| Setting | Peak RSS (MB) | RSS at end (MB) | CPU (s) | Frames |
| --- | --- | --- | --- | --- |
| `o=80` | 81.8 | 65.6 | 11.7 | 85428 |
| `o=120` (default) | 87.1 | 74.3 | 11.2 | 85412 |
| `o=200` | 89.1 | 76.7 | 11.6 | 85394 |
| `o=400` | 101.3 | 84.7 | 11.7 | 85389 |

Reading them:

- Memory follows `o` as expected, so the runtime honours the variable: RSS at the
  end of the run goes from 66 MB (`o=80`) to 85 MB (`o=400`), peak from 82 to 101 MB.
- CPU does not measurably follow it at this load: the recorder uses about 2% of a core
  (11-12 s over 600 s) and the spread between settings (0.3 to 0.7 s) is within the
  noise between runs. The GC is not where the recorder's CPU goes.
- A bigger minor heap (`s=1M`) changed neither: the recorder's allocations are
  short-lived frames that die young either way.
- For the recorder the default is fine. If a node is memory-bound (many venues per
  pod), `o=80` saves about 10% RSS for no visible CPU; raising `o` only costs memory.
- To set it: `environment: OCAMLRUNPARAM: o=80` in compose, or an `env` entry on the
  recorder container in the chart.
- `v=0x400` (GC statistics at exit) prints nothing on this runtime, so the script does
  not rely on it; `Gc.quick_stat` from inside the program is the way to get counts.

## memtrace on the ox base image

memtrace builds and records on the OxCaml base image. Tried on
`ghcr.io/winterchill-trading/oxcaml-base:latest`:

```sh
opam install memtrace     # memtrace.v0.18~preview.130.106+341, from the ox repository
```

A test program calling `Memtrace.trace_if_requested ()`, run with
`MEMTRACE=/tmp/trace.ctf MEMTRACE_RATE=1e-3`, wrote a 58 KB trace; reading it back
with `Memtrace.Trace.Reader` gave 4638 sampled allocations, 136 promotions and 4055
collections, which matches the program's allocation pattern. So statistical memory
profiling (Memprof) works on the ox runtime 5, unlike upstream OCaml 5.0 to 5.2.

Notes for wiring it into a service:

- memtrace is not in the base image's library layer, and does not need to be: a
  service that adds it to its `dune-project` gets it from `opam install . --deps-only`
  in the service image build (it is a small package with no C dependencies beyond the
  runtime).
- The default sampling rate (`1e-6`) records almost nothing for a short run; use
  `MEMTRACE_RATE=1e-4` or so for minutes-long captures.
- The trace path must be writable: in the chart the recorder's root filesystem is
  read-only, so point `MEMTRACE` at `/tmp` (an emptyDir) or the data volume, then copy
  it out with `kubectl cp`. View it with `memtrace-viewer` on a workstation.

## Tracing the recorder

The wiring only sets the environment; the recorder binary must call
`Memtrace.trace_if_requested ()` at startup for a trace to appear. As of
2026-10-12 market-recorder does not link memtrace yet, so the variables below are
inert until it does (an empty `MEMTRACE` is a no-op either way).

Compose. The recorder always gets `MEMTRACE` and `MEMTRACE_RATE` from
`RECORDER_MEMTRACE` and `RECORDER_MEMTRACE_RATE`, empty by default. It is not a
compose profile: profiles add services, and a second recorder service would record
into the same volume twice.

```sh
make up-memtrace                    # recreate the recorder with MEMTRACE_RATE=1e-4
make up-memtrace MEMTRACE_RATE=1e-3 # denser sample, for a short capture
# ... let it run ...
make memtrace-pull                  # ./memtrace.ctf (git-ignored)
make up                             # back to no tracing
```

Helm. `--set recorder.memtrace.enabled=true` (and `recorder.memtrace.rate`) sets
`MEMTRACE=<dataDir>/memtrace.ctf` on every recorder. The file is on the PVC, so it
survives a crash or an OOM kill, but the next start overwrites it: copy it out
before a restart.

```sh
helm upgrade winterchill charts/winterchill -f charts/winterchill/values-dev.yaml \
  --set recorder.memtrace.enabled=true
kubectl cp deploy/winterchill-recorder-binance:/var/lib/market-recorder/memtrace.ctf memtrace.ctf
```

The trace is written as it goes (buffered), so copying it from a running process
gives a usable prefix; stopping the process flushes the rest.

Reading it, on a workstation with the ox switch:

- `memtrace-viewer memtrace.ctf` (opam package `memtrace_viewer`) serves an
  interactive flame graph of live and allocated words by call site on
  http://localhost:8080. Start with "live" at the end of the trace for a leak,
  "allocations" for GC pressure.
- The `memtrace` package installs command-line readers: `memtrace_hotspots`
  (heaviest allocation sites), `memtrace_flamegraph` (folded stacks for
  `flamegraph.pl` or speedscope) and `memtrace_dump_trace` (every event).
- Sizes in the viewer are sampled and scaled back up by `1 / rate`; with
  `1e-4` an allocation site needs about 10k words allocated to appear at all.
