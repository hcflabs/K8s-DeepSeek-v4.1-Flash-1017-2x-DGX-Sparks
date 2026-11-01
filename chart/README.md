# dsv41-flash-1017-tensorfold chart

Serves DeepSeek-V4.1-Flash-1017 (EXL3 EAQ 2.9 bpw, 1M window, images, DSpark
drafts) tensor-parallel (TP=2) across two DGX Spark nodes with TensorFold's
native Zig engine and Mia's AI Lab patch series: a leader Deployment (rank 0,
`tensorfold-native serve`, the API on `:8888`) and a worker Deployment (rank 1,
`tf-dsv41-lanes`). Both are `hostNetwork` and privileged (RoCE).

Each pod first runs the `prepare` init container: RoPE tables, the image
routing bias, the kit check, Engram's token map, the rank's ~106 GB weight file
and the served folder, all from the checkpoint and all skipped when done.

Prerequisites: both nodes joined with the rank labels and GPU taint, the link
up, `scripts/prepare-model.sh` run for both nodes, the image built
(`scripts/build-image.sh` or the image workflow), and the NVIDIA device plugin.
See the top-level README.

Resources are named `<release>-dsv41-flash-1017-tensorfold-*` unless the release
name already contains `dsv41-flash-1017-tensorfold` or `fullnameOverride` is set.

## Install

```bash
helm upgrade --install dsv41-flash-1017-tensorfold ./chart -n tensorfold --create-namespace -f my-values.yaml
# or, released:
helm upgrade --install dsv41-flash-1017-tensorfold oci://ghcr.io/hcflabs/charts/dsv41-flash-1017-tensorfold \
  --version <version> -n tensorfold --create-namespace -f my-values.yaml
```

k3s helm-controller:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: dsv41-flash-1017-tensorfold
  namespace: kube-system
spec:
  chart: oci://ghcr.io/hcflabs/charts/dsv41-flash-1017-tensorfold
  version: <version>
  targetNamespace: tensorfold
  createNamespace: true
  valuesContent: |-
    topology:
      fabric: {masterAddr: <leader-ip>, workerAddr: <worker-ip>, interface: <netdev>, rdmaDevice: <dev0,dev1>, gidIndex: <n>}
    weights:
      hostPath: {leader: <root>, worker: <root>}
```

## Required values

`topology.fabric.masterAddr`, `.interface`, `.rdmaDevice`, `.gidIndex` and
`weights.hostPath.leader` / `.worker`. Rendering fails without them, and on
settings upstream's `start.sh` refuses (`serving.context` above 1048576,
`parallelRequests` above 16, a `pool` below `context`, `roundRows` other than 16,
an unknown `reasoningEffort`). `values.yaml` documents every key; `ENVS.md` maps
them to upstream's settings.

## Memory

A Spark's GPU shares its 121 GiB with the host; a rank that takes it all
freezes the node. `serve.sh` refuses to launch below `memory.minAvailGiB` (112)
and kills the engine when MemAvailable stays under `memory.guardGiB` (2.5).
Do not set a memory limit (the engine is killed while loading). Upstream:
on a node that runs other software, `serving.context: 524288` is the practical
limit (`docs/upstream/memory-and-safety.md`).
