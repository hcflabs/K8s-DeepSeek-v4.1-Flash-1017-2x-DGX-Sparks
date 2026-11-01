# Settings

Upstream settings (`scripts/config.sh`, `start.sh`) and their chart values.
Defaults are upstream's unless noted.

| Upstream | Chart value | Default | Reaches the engine as |
| --- | --- | --- | --- |
| `CONTEXT` | `serving.context` | 1048576 | rank 0 `--context`; rank 1 `--pool` (when no pool) |
| `POOL` | `serving.pool` | "" | `TF_DS_POOL`, `TF_DS_WINDOW`; rank 1 `--pool` |
| `PARALLEL` | `serving.parallelRequests` | 4 | rank 0 `--parallel`; rank 1 `--streams`; `TF_DS_STREAMS` |
| `MAX_TOKENS` | `serving.maxTokens` | 32768 | `--max-tokens` |
| `THINKING` | `serving.thinking` | true | `--thinking` / `--no-thinking` |
| `REASONING_EFFORT` | `serving.reasoningEffort` | "" | `--reasoning-effort` |
| `THINKING_BUDGET` | `serving.thinkingBudget` | "" | `--thinking-budget` |
| `TEMPERATURE`, `TOP_P`, `TOP_K` | `serving.temperature`, `.topP`, `.topK` | 1.0, 0.95, 20 | `--temperature`, `--top-p`, `--top-k` |
| `DRAFTS` | `serving.drafts` | true | rank 0 `--no-drafts` when off; rank 1 `--drafts` |
| `ROUND_ROWS` | `serving.roundRows` | "" | `TF_DS_ROUND_ROWS`; rank 1 `--round-rows` |
| `PREFILL_INTERLEAVE_MS` | `serving.prefillInterleaveMs` | 250 | `TF_DS_PREFILL_INTERLEAVE_MS` |
| `SERVED_NAME` | `model.servedName` | DeepSeek-V4.1-Flash-1017 | `--name` |
| `PORT` | `service.port` | 8888 | `--port` (`hostNetwork`: the leader node's port) |
| `HOST` | — | 0.0.0.0 | `--host` (fixed: rank 1 watches rank 0's `/health` over the link) |
| extra `./start.sh` args | `serving.extraArgs` | "" | appended to rank 0's serve command |
| `RDMA` | `engine.rdma` | true | rank 0 `TF_RDMA_DEVICES`; rank 1 `--rdma` |
| `RDMA_IDLE_S`, `RDMA_NAP_US` | `engine.rdmaIdleS`, `.rdmaNapUs` | 2, 500 | `TF_RDMA_IDLE_S`, `TF_RDMA_NAP_US` |
| `GRAPHS`, `GRAPH_CAP` | `engine.graphs`, `.graphCap` | true, 128 | rank 0 `TF_DS_GRAPHS`, `TF_DS_GRAPH_CAP`; rank 1 `--graphs`, `--graph-cap` |
| `SIDE`, `PREFETCH`, `ENGRAM_AIO` | `engine.side`, `.prefetch`, `.engramAio` | true | rank 0 `TF_DS_HC_SIDE`, `TF_DS_L2_PREFETCH`, `TF_DS_ENGRAM_AIO`; rank 1 `--side`, `--prefetch`, `--aio` |
| `REPLAY_FLOOR` | `engine.replayFloor` | true | `TF_DS_REPLAY_FLOOR` |
| `RANK1_PROFILE` | `engine.rank1Profile` | 0 | rank 1 `--profile` |
| `TENSORFOLD_*`, `TF_DS_*`, `TF_FILL_*` passthrough | `engine.env` (map) or `serving.extraEnv` (list) | — | both ranks |
| `MASTER_ADDR` | `topology.fabric.masterAddr` | required | `TF_TP_MASTER`; rank 1's connect address |
| `MASTER_PORT` | `topology.fabric.port` | 29620 | `TF_TP_PORT`; rank 1's port argument |
| `TF_DS_CONNECT_S` | `topology.fabric.connectSeconds` | 1800 (upstream 300) | `TF_DS_CONNECT_S` |
| link netdev (found) | `topology.fabric.interface` | required | `NCCL_SOCKET_IFNAME` |
| RoCE devices, both rails (found) | `topology.fabric.rdmaDevice` | required | `NCCL_IB_HCA`, `TF_RDMA_DEVICES`, `--rdma` |
| RoCE v2 GID (found) | `topology.fabric.gidIndex` | required | `NCCL_IB_GID_INDEX`, `TF_RDMA_GID_INDEX` |
| `NCCL_DEBUG` | `nccl.debug`, `nccl.debugSubsys` | "" | `NCCL_DEBUG`, `NCCL_DEBUG_SUBSYS` |
| `MIN_AVAIL_GIB`, `MIN_AVAIL_WAIT_S` | `memory.minAvailGiB`, `.minAvailWaitS` | 112, 120 | checked by `serve.sh` before the launch |
| `MEMGUARD_GIB`, `_HOLD_S`, `_HARD_GIB` | `memory.guardGiB`, `.guardHoldS`, `.guardHardGiB` | 2.5, 4, 1 | `serve.sh`'s in-container memguard |
| `FOREGROUND` supervision | `memory.leaderWatchSeconds` | 60 | rank 1 exits when rank 0's `/health` is gone that long |
| `API_KEY`, `API_KEY_FILE` | `auth.existingSecret`/`existingSecretKey`, `auth.apiKey(s)` | open | `--api-key-file` (rank 0) |
| `HF_CACHE`, `NFS_*`, `WORKER_*_DIR`, `HEAD_*` | `weights.hostPath.leader` / `.worker` | required | one root per node: `checkpoint/`, `engram/`, `kit/`, `data/` |
| `EAQ_V1_1`, `MODEL_ID`, `MODEL_REVISION` | `scripts/prepare-model.sh --eaq-v1-1` | EAQ v1 | the checkpoint in `checkpoint/` |
| `VERIFY_SHA` | `scripts/prepare-model.sh --verify-sha` | off | |
| `ABLIT` | `ablit.enabled` (+ `scripts/prepare-model.sh --ablit`) | off | `TENSORFOLD_ABLIT`, both ranks and the init container |
| `ABLIT_REVISION` | `ablit.revision` | `0bdc2036...` | full commit hash; `data/ablit-<rev8>/` |
| `SPILL_*`, `KV_SHARD*` | not ported (SYNC.md) | off | |
