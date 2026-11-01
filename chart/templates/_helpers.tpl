{{- define "dsv41.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "dsv41.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "dsv41.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "dsv41.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: dsv41-flash-1017-tensorfold
{{- end -}}

{{- define "dsv41.selectorLabels" -}}
app.kubernetes.io/name: {{ include "dsv41.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "dsv41.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s:%s@%s" .Values.image.repository .Values.image.tag .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end -}}

{{/* Secret holding the API keys, or empty when /v1 is unauthenticated. */}}
{{- define "dsv41.authSecretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else if or .Values.auth.apiKey .Values.auth.apiKeys -}}
{{- printf "%s-api-key" (include "dsv41.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* "1"/"0" from a boolean-ish value. */}}
{{- define "dsv41.bool" -}}
{{- ternary "1" "0" (has (toString . | lower) (list "true" "1")) -}}
{{- end -}}

{{/* A value as a string, or "" when unset (null or ""); 0 stays "0". */}}
{{- define "dsv41.optional" -}}
{{- if not (kindIs "invalid" .) }}{{ toString . }}{{ end -}}
{{- end -}}

{{/* Upstream start.sh's checks on the settings, at render time. */}}
{{- define "dsv41.validate" -}}
{{- $s := .Values.serving -}}
{{- $ctx := int $s.context -}}
{{- if or (lt $ctx 1) (gt $ctx 1048576) }}{{ fail (printf "serving.context is 1 to 1048576 (the model's window), not %v" $s.context) }}{{ end }}
{{- $p := int $s.parallelRequests -}}
{{- if or (lt $p 1) (gt $p 16) }}{{ fail (printf "serving.parallelRequests is 1 to 16, not %v" $s.parallelRequests) }}{{ end }}
{{- with include "dsv41.optional" $s.pool }}{{ if lt (int .) $ctx }}{{ fail (printf "serving.pool is empty or at least serving.context (%d), not %s" $ctx .) }}{{ end }}{{ end }}
{{- with include "dsv41.optional" $s.roundRows }}{{ if ne . "16" }}{{ fail (printf "serving.roundRows is empty or 16 (the pinned kit has no wider row kernels), not %s" .) }}{{ end }}{{ end }}
{{- with $s.reasoningEffort }}{{ if not (has . (list "low" "medium" "high" "xhigh")) }}{{ fail (printf "serving.reasoningEffort is low, medium, high, xhigh or empty, not %s" .) }}{{ end }}{{ end }}
{{- $pim := int $s.prefillInterleaveMs -}}
{{- if or (lt $pim 0) (gt $pim 5000) }}{{ fail "serving.prefillInterleaveMs is 0 to 5000" }}{{ end }}
{{- if not (has (toString .Values.engine.rank1Profile) (list "0" "1" "2")) }}{{ fail "engine.rank1Profile is 0, 1 or 2" }}{{ end }}
{{- end -}}

{{/* Per-rank container environment. Args: dict "root" . "rank" 0|1 */}}
{{- define "dsv41.env" -}}
{{- $v := .root.Values -}}
{{- $f := $v.topology.fabric -}}
{{- $s := $v.serving -}}
{{- $e := $v.engine -}}
{{- $gid := required "topology.fabric.gidIndex is required (the RoCE v2 IPv4 GID index)" (include "dsv41.optional" $f.gidIndex) -}}
- {name: TENSORFOLD_NODE_RANK, value: {{ .rank | quote }}}
- {name: TENSORFOLD_ROOT, value: "/models"}
- {name: TENSORFOLD_MASTER_ADDR, value: {{ required "topology.fabric.masterAddr is required" $f.masterAddr | quote }}}
- {name: TENSORFOLD_MASTER_PORT, value: {{ $f.port | quote }}}
- {name: TENSORFOLD_API_PORT, value: {{ $v.service.port | quote }}}
- {name: TENSORFOLD_SERVED_MODEL_NAME, value: {{ $v.model.servedName | quote }}}
- {name: TENSORFOLD_CONTEXT, value: {{ $s.context | quote }}}
- {name: TENSORFOLD_POOL, value: {{ include "dsv41.optional" $s.pool | quote }}}
- {name: TENSORFOLD_PARALLEL, value: {{ $s.parallelRequests | quote }}}
- {name: TENSORFOLD_MAX_TOKENS, value: {{ $s.maxTokens | quote }}}
- {name: TENSORFOLD_THINKING, value: {{ include "dsv41.bool" $s.thinking | quote }}}
- {name: TENSORFOLD_REASONING_EFFORT, value: {{ $s.reasoningEffort | default "" | quote }}}
- {name: TENSORFOLD_THINKING_BUDGET, value: {{ include "dsv41.optional" $s.thinkingBudget | quote }}}
- {name: TENSORFOLD_TEMPERATURE, value: {{ $s.temperature | quote }}}
- {name: TENSORFOLD_TOP_P, value: {{ $s.topP | quote }}}
- {name: TENSORFOLD_TOP_K, value: {{ $s.topK | quote }}}
- {name: TENSORFOLD_DRAFTS, value: {{ include "dsv41.bool" $s.drafts | quote }}}
- {name: TENSORFOLD_ROUND_ROWS, value: {{ include "dsv41.optional" $s.roundRows | quote }}}
- {name: TENSORFOLD_EXTRA_ARGS, value: {{ $s.extraArgs | default "" | quote }}}
- {name: TENSORFOLD_RDMA, value: {{ include "dsv41.bool" $e.rdma | quote }}}
- {name: TENSORFOLD_RDMA_DEVICES, value: {{ required "topology.fabric.rdmaDevice is required" $f.rdmaDevice | quote }}}
- {name: TENSORFOLD_GRAPHS, value: {{ include "dsv41.bool" $e.graphs | quote }}}
- {name: TENSORFOLD_GRAPH_CAP, value: {{ $e.graphCap | quote }}}
- {name: TENSORFOLD_SIDE, value: {{ include "dsv41.bool" $e.side | quote }}}
- {name: TENSORFOLD_PREFETCH, value: {{ include "dsv41.bool" $e.prefetch | quote }}}
- {name: TENSORFOLD_ENGRAM_AIO, value: {{ include "dsv41.bool" $e.engramAio | quote }}}
- {name: TENSORFOLD_RANK1_PROFILE, value: {{ $e.rank1Profile | quote }}}
- {name: TENSORFOLD_MIN_AVAIL_GIB, value: {{ $v.memory.minAvailGiB | quote }}}
- {name: TENSORFOLD_MIN_AVAIL_WAIT_S, value: {{ $v.memory.minAvailWaitS | quote }}}
- {name: TENSORFOLD_MEMGUARD_GIB, value: {{ $v.memory.guardGiB | quote }}}
- {name: TENSORFOLD_MEMGUARD_HOLD_S, value: {{ $v.memory.guardHoldS | quote }}}
- {name: TENSORFOLD_MEMGUARD_HARD_GIB, value: {{ $v.memory.guardHardGiB | quote }}}
- {name: TENSORFOLD_LEADER_WATCH_S, value: {{ $v.memory.leaderWatchSeconds | quote }}}
{{- /* the engine's variables, both ranks alike (upstream ENGINE_ENV) */}}
- {name: TF_DS_REPLAY_FLOOR, value: {{ include "dsv41.bool" $e.replayFloor | quote }}}
- {name: TF_RDMA_IDLE_S, value: {{ $e.rdmaIdleS | quote }}}
- {name: TF_RDMA_NAP_US, value: {{ $e.rdmaNapUs | quote }}}
- {name: TF_RDMA_GID_INDEX, value: {{ $gid | quote }}}
- {name: TF_DS_CONNECT_S, value: {{ $f.connectSeconds | quote }}}
{{- if ne (int $s.prefillInterleaveMs) 0 }}
- {name: TF_DS_PREFILL_INTERLEAVE_MS, value: {{ $s.prefillInterleaveMs | quote }}}
{{- end }}
- {name: HF_HUB_OFFLINE, value: "1"}
- {name: NCCL_SOCKET_IFNAME, value: {{ required "topology.fabric.interface is required" $f.interface | quote }}}
- {name: NCCL_IB_HCA, value: {{ $f.rdmaDevice | quote }}}
- {name: NCCL_IB_GID_INDEX, value: {{ $gid | quote }}}
{{- with $v.nccl.debug }}
- {name: NCCL_DEBUG, value: {{ . | quote }}}
{{- end }}
{{- with $v.nccl.debugSubsys }}
- {name: NCCL_DEBUG_SUBSYS, value: {{ . | quote }}}
{{- end }}
{{- $env := default dict $e.env }}
{{- range $k := keys $env | sortAlpha }}
{{- $val := get $env $k }}
{{- if not (kindIs "invalid" $val) }}
- {name: {{ $k }}, value: {{ $val | toString | quote }}}
{{- end }}
{{- end }}
{{- if eq (int .rank) 0 }}
{{- with (include "dsv41.authSecretName" .root) }}
- name: TENSORFOLD_API_KEYS
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: {{ if $v.auth.existingSecret }}{{ $v.auth.existingSecretKey }}{{ else }}token{{ end }}
{{- end }}
{{- end }}
{{- with $s.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Pod spec shared by both ranks. Args: dict "root" . "rank" 0|1 "component" leader|worker */}}
{{- define "dsv41.podSpec" -}}
{{- $v := .root.Values -}}
{{- $isLeader := eq (int .rank) 0 -}}
{{- include "dsv41.validate" .root -}}
enableServiceLinks: false
hostNetwork: true
dnsPolicy: ClusterFirstWithHostNet
{{- with $v.runtimeClassName }}
runtimeClassName: {{ . }}
{{- end }}
{{- with $v.imagePullSecrets }}
imagePullSecrets:
{{ toYaml . | indent 2 }}
{{- end }}
# The engine exits on SIGTERM; give it time to free the GPU before the next pod.
terminationGracePeriodSeconds: 60
nodeSelector:
  {{ $v.topology.rankLabels.key }}: {{ ternary $v.topology.rankLabels.leader $v.topology.rankLabels.worker $isLeader | quote }}
tolerations:
  - {{ toYaml $v.topology.gpuToleration | nindent 4 | trim }}
{{- if $v.prepare.enabled }}
initContainers:
  - name: prepare
    image: {{ include "dsv41.image" .root | quote }}
    imagePullPolicy: {{ $v.image.pullPolicy }}
    command: [bash, /etc/tensorfold/prepare.sh]
    env:
      - {name: TENSORFOLD_NODE_RANK, value: {{ .rank | quote }}}
      - {name: TENSORFOLD_ROOT, value: "/models"}
      - {name: TENSORFOLD_CHAT_TEMPLATE, value: "/etc/tensorfold/chat_template.jinja"}
      - {name: TENSORFOLD_VERIFY_KIT, value: {{ include "dsv41.bool" $v.prepare.verifyKit | quote }}}
      - {name: TENSORFOLD_MIN_FREE_GIB, value: {{ $v.prepare.minFreeGiB | quote }}}
      - {name: HOME, value: /tmp}
    {{- with $v.prepare.resources }}
    resources:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    volumeMounts:
      - {name: models, mountPath: /models}
      - {name: serve, mountPath: /etc/tensorfold}
{{- end }}
containers:
  - name: tensorfold
    image: {{ include "dsv41.image" .root | quote }}
    imagePullPolicy: {{ $v.image.pullPolicy }}
    command: [bash, /etc/tensorfold/serve.sh]
{{- if $isLeader }}
    ports:
      - {name: http, containerPort: {{ $v.service.port }}}
{{- end }}
    env:
{{ include "dsv41.env" . | indent 6 }}
    resources:
{{ toYaml $v.resources | indent 6 }}
    securityContext:
      privileged: true
    volumeMounts:
      - {name: models, mountPath: /models, readOnly: true}
      - {name: serve, mountPath: /etc/tensorfold}
      - {name: rdma, mountPath: /dev/infiniband}
      - {name: shm, mountPath: /dev/shm}
      - {name: run, mountPath: /run/tensorfold}
{{- if $isLeader }}
    startupProbe:
      httpGet: {path: /health, port: http}
{{ toYaml $v.probes.startup | indent 6 }}
    livenessProbe:
      httpGet: {path: /health, port: http}
{{ toYaml $v.probes.liveness | indent 6 }}
    readinessProbe:
      httpGet: {path: /health, port: http}
{{ toYaml $v.probes.readiness | indent 6 }}
{{- end }}
volumes:
  - name: models
    hostPath:
      path: {{ required (printf "weights.hostPath.%s is required" (ternary "leader" "worker" $isLeader)) (ternary $v.weights.hostPath.leader $v.weights.hostPath.worker $isLeader) | quote }}
      type: Directory
  - name: serve
    configMap:
      name: {{ include "dsv41.fullname" .root }}-serve
  - name: rdma
    hostPath:
      path: /dev/infiniband
      type: Directory
  - name: shm
    emptyDir:
      medium: Memory
      sizeLimit: {{ $v.shm.sizeLimit }}
  - name: run
    emptyDir:
      medium: Memory
      sizeLimit: 1Mi
{{- end -}}
