# Upstream sync

Derived from `MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks` (git remote
`upstream`, read-only). This repository started as a copy of it; the Docker
launcher was replaced by a Helm chart.

- **Pinned upstream ref:** `main` at `0e7d421` (2026-10-29; 33 engine patches,
  `zig/patches/0001`-`0038`, and 2 inputs patches).
- **Engine:** BertholomusAI's TensorFold fork, branch `deepseek-v41-zig`, at
  `TF_REF` `fbbc9713`; the inputs' tools from branch `deepseek-v41-zig-tp4` at
  `INPUTS_REF` `59402086`; Zig 0.17.0 on `nvcr.io/nvidia/pytorch:26.07-py3`.
  All pins are in `scripts/image.env`, copied from upstream `scripts/config.sh`.
- **Image:** upstream publishes none (`GHCR_IMAGE` is unused there), so this repo
  builds `ghcr.io/hcflabs/dsv41-flash-1017-tensorfold:exl3-tp2-<hash>` from
  `zig/` unchanged (`scripts/build-image.sh`, `.github/workflows/image.yml`).
  The hash is upstream's `image_hash`, so the tag equals upstream's local tag
  `tensorfold-dsv41:exl3-tp2-<hash>` for the same pins.
- **Weights and kit pins:** in `scripts/prepare-model.sh` (checkpoint EAQ v1
  `45ee5d0f`, v1.1 `aee640e2`; Engram `deepseek-ai/DeepSeek-V4.1-Flash-1017`
  `1bae0e10`; kit `abe07c7d`).

## What is kept from upstream, unchanged

| Path | Use |
| --- | --- |
| `zig/Dockerfile`, `zig/patches/`, `zig/patches-inputs/` | the image build context |
| `chart/files/chat_template.jinja` | upstream `model/chat_template.jinja`, served by rank 0 |
| `tools/` | client-side checks (`validate.py`, `smoke.py`, `bench.py`, `toolcheck.py`, ...): point them at the Service URL. `gpu_validate.sh`, `selftest.py` and the spill/KV-shard checks drive upstream's `start.sh` and do not apply here |
| `docs/upstream/` | upstream's README, CHANGELOG and docs, for reference |
| `CREDITS.md`, `NOTICE`, `LICENSE` | |

## Port

| Upstream | Here |
| --- | --- |
| `start.sh` rank 0 / rank 1 `docker run` | `chart/files/serve.sh`, one Deployment per rank (`hostNetwork`, privileged, `/dev/infiniband`) |
| `scripts/prepare.sh` steps 3 (downloads), 4 (kit fetch) | `scripts/prepare-model.sh` over SSH, on **both** nodes |
| `scripts/prepare.sh` steps 4-5, 7 (RoPE, image bias, MANIFEST, token map, weight file, served folder) | `chart/files/prepare.sh`, the `prepare` init container, per rank |
| `scripts/prepare.sh` step 2 (image) | `scripts/build-image.sh`, `image.yml` |
| `scripts/nodes.sh` link detection | given: `topology.fabric.*` (Ansible owns the link) |
| `MIN_AVAIL_GIB` check, `scripts/memguard.sh` | in `serve.sh`, inside the container |
| `FOREGROUND=1` supervision (either rank ending ends both) | rank 0 exits with status 75 on a broken pair (patch 0020); rank 1 exits when rank 0's `/health` is gone `memory.leaderWatchSeconds`; Kubernetes restarts both |
| rank 1 started first | rank 0 opens the rendezvous port early (patch 0037); rank 1 retries `TF_DS_CONNECT_S` (`topology.fabric.connectSeconds`, 1800 here) |
| `API_KEY=1` key file | `auth.*` secret, written to `--api-key-file` one key a line |

Differences, on purpose:

- **No NFS.** Each node has its own checkpoint, Engram tables and kit (~505 GB
  a node). Upstream recommends local Engram tables on both Sparks anyway
  (prefill ~2,100 tok/s local against ~690-890 over NFS).
- **No link detection.** NCCL and the engine's RoCE exchanges use
  `topology.fabric.rdmaDevice` and `gidIndex` as given. Upstream's
  `probe_rails` (drop a twin rail that cannot reach the peer) has no
  counterpart; the Ansible playbook checks the link.
- **`ABLIT=1`** is `ablit.enabled` (pin `ablit.revision`). `prepare-model.sh
  --ablit` fetches the gated overlay on each node (no token reaches the cluster);
  the init container applies it and runs `ablit_stock_dtypes.py` (copied as is
  to `chart/files/`) into `data/ablit-<rev8>/`, which has its own `rank-cache/`
  and `model/`. Upstream's running-mode check in `start.sh` is the serve log's
  `mode:` line. Upstream's measurements do not cover this mode.
- **Not ported:** spill v2 and KV sharding (off by
  default upstream; they need per-node spill directories and identity checks),
  `HEAD_NFS_*`, log rotation (Kubernetes rotates container logs), the systemd
  unit. `engine.env` and `serving.extraArgs` pass raw `TF_DS_*` settings and
  serve flags through, but the chart does not check them.

## Syncing

```bash
git fetch upstream
git diff 0e7d421 upstream/main --stat -- zig scripts/config.sh start.sh scripts/prepare.sh model
```

- `zig/**`, `model/chat_template.jinja`: take them (`git checkout upstream/main --
  zig`, copy the template to `chart/files/`), then `scripts/image-tag.sh` gives
  the new tag. Build and push the image, set `image.tag`/`appVersion`.
- `scripts/config.sh` pins (`TF_REF`, `INPUTS_REF`, `KIT_REF`, revisions, Zig,
  base image): copy into `scripts/image.env` / `scripts/prepare-model.sh`.
- New settings or flags in `start.sh`: map them in `serve.sh`, `_helpers.tpl`,
  `values.yaml` and `ENVS.md`.
- Update the pinned ref above.

## Git remote and `gh`

```bash
git remote add upstream https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks.git
gh repo set-default hcflabs/K8s-DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks
```
