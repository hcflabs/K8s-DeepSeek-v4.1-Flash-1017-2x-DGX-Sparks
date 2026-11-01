# DeepSeek-V4.1-Flash-1017 on two DGX Sparks with TensorFold - Kubernetes/k3s

[![ci](https://github.com/hcflabs/K8s-DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks/actions/workflows/ci.yml/badge.svg)](https://github.com/hcflabs/K8s-DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks/actions/workflows/ci.yml)

A Helm chart, host scripts and an Ansible layer that run Mia's AI Lab recipe
[MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks)
on a k3s cluster instead of `./start.sh` and Docker:

- **Model:** [`Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw`](https://huggingface.co/Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw)
  (196 GiB), with Engram's tables from the base model, a 1,048,576-token window,
  images, tool calls, thinking on or off, DSpark drafts.
- **Engine:** TensorFold's native Zig engine (BertholomusAI's `dsv41` family, TP=2),
  with **upstream's patch series** (`zig/patches`, 34 patches) baked into the image
  this repository builds.
- **API:** OpenAI-compatible (and Anthropic Messages), model id
  `DeepSeek-V4.1-Flash-1017`, port 8888 on the leader.

Upstream reports ~81 tok/s for one stream, ~154 tok/s total for four, and
~2,100 tok/s prefill on the same hardware (`docs/upstream/README.md`).

## Layout

```
chart/                  the Helm chart (leader + worker Deployments, Service, Ingress)
chart/files/serve.sh    each rank's entrypoint (upstream start.sh's launch, memory guards)
chart/files/prepare.sh  the init container (upstream prepare.sh's derived files)
chart/files/chat_template.jinja   the template rank 0 serves (upstream model/)
zig/                    the image build context, from upstream, unchanged
scripts/prepare-model.sh   checkpoint, Engram tables and kit on both nodes, over SSH
scripts/build-image.sh  build the image on a Spark; push and/or import into k3s
scripts/image-tag.sh, image.env   the image's pins and tag (upstream image_hash)
scripts/verify-dsv41.sh read-only readiness report (weights, image, fabric, labels, pods, API)
scripts/smoke-dsv41.sh  /health, /v1/models, the window, one chat reply
scripts/apply.sh        NVIDIA device plugin, then the chart
ansible/                bare Sparks -> k3s agents (fabric, runtime check, join)
tools/                  upstream's client checks (validate.py, bench.py, ...)
docs/upstream/          upstream's docs, for reference
SYNC.md, ENVS.md        what was ported and how; every setting's chart value
```

## Requirements

- Two DGX Sparks joined to k3s as agents, labelled `node.tensorfold/rank=leader`
  and `=worker`, tainted `nvidia.com/gpu=present:NoSchedule`, the NVIDIA device
  plugin advertising `nvidia.com/gpu`.
- The direct ConnectX-7 link, addressed on both ends (both PCIe twins, ideally),
  RoCE ACTIVE. You give its addresses, netdev, RoCE devices and GID index.
- **Nothing else large on either GPU:** each rank holds ~98 GiB, and `serve.sh`
  waits for 112 GiB available before it launches.
- **Disk:** ~505 GB on each node (checkpoint 196 GiB, Engram 203 GB, the rank's
  weight file ~106 GB), plus ~25 GB for the image.

## Quick start

```bash
# 1. weights, Engram's tables and the kit on both nodes (resumable; hours the first time)
scripts/prepare-model.sh --models-dir /data/models admin@spark-1 admin@spark-2

# 2. the image (no published one upstream): on a Spark with nothing serving
scripts/build-image.sh --import admin@spark-1 --import admin@spark-2 admin@spark-1
#    or push it to ghcr: GHCR_TOKEN=... scripts/build-image.sh --push admin@spark-1
#    or: gh workflow run image.yml

# 3. the chart
cat > my-values.yaml <<'EOF'
topology:
  fabric: {masterAddr: 192.168.100.1, workerAddr: 192.168.100.2, interface: enp1s0f1np1,
           rdmaDevice: "rocep1s0f1,roceP2p1s0f1", gidIndex: 3}
weights:
  hostPath: {leader: /data/models/DeepSeek-V4.1-Flash-1017, worker: /data/models/DeepSeek-V4.1-Flash-1017}
auth: {apiKey: change-me}
EOF
scripts/apply.sh -f my-values.yaml

# 4. watch and check
kubectl get pods -n tensorfold -w
kubectl logs -n tensorfold deploy/dsv41-flash-1017-tensorfold-leader -c prepare -f
scripts/verify-dsv41.sh --leader admin@spark-1 --worker admin@spark-2 --leader-fabric-ip 192.168.100.1 \
  --worker-fabric-ip 192.168.100.2 --fabric-if enp1s0f1np1 --rdma-dev rocep1s0f1,roceP2p1s0f1 \
  --root /data/models/DeepSeek-V4.1-Flash-1017
API_KEY=change-me scripts/smoke-dsv41.sh
```

The first start of each pod writes its rank's weight file in the init
container (a few minutes); later starts skip it and load ~98 GiB of weights.
Rank 1 waits for rank 0 for up to `topology.fabric.connectSeconds`. When either
rank fails, the other one ends too and Kubernetes restarts both.

The model thinks before it answers unless a request turns thinking off, so give
replies enough `max_tokens`. The full window is 1,048,576 tokens; on Sparks that
also run other software upstream calls 524,288 the practical limit
(`serving.context`).

## Upgrading

The chart is released from GitHub Actions (`RELEASING.md`) to
`oci://ghcr.io/hcflabs/charts/dsv41-flash-1017-tensorfold`. Engine changes
come from upstream (`SYNC.md`): sync `zig/`, build the new image, set
`image.tag`, release.

## Credits

The recipe, its patches and the EAQ quantization are Mia's AI Lab's; the
engine and kit are BertholomusAI's and TensorFold's. See `CREDITS.md` and
`NOTICE`. Licence: Apache-2.0.
