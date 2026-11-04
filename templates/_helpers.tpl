{{/*
Expand the name of the chart.
*/}}
{{- define "dockerhelm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "dockerhelm.fullname" -}}
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
{{- end }}

{{/*
Name of the governing headless Service for StatefulSet.
Both serviceName in statefulset.yaml and metadata.name in headless-service.yaml
come from here, ensuring they always match (single point of control).
*/}}
{{- define "dockerhelm.headlessServiceName" -}}
{{- printf "%s-headless" (include "dockerhelm.fullname" . | trunc 54 | trimSuffix "-") -}}
{{- end }}

{{/*
The following three name helpers are the single source of truth that keeps resource
creators and mounters in sync (configmap.yaml/secret.yaml/pvc.yaml ↔ volume references in _podSpec.tpl).
*/}}
{{- define "dockerhelm.configMapName" -}}
{{- default (include "dockerhelm.fullname" .) .Values.configMap.name -}}
{{- end }}

{{- define "dockerhelm.secretName" -}}
{{- default (include "dockerhelm.fullname" .) .Values.secret.name -}}
{{- end }}

{{- define "dockerhelm.pvcName" -}}
{{- printf "%s-%s" (include "dockerhelm.fullname" .) .Values.persistence.name -}}
{{- end }}

{{/*
Shared strategy / updateStrategy rendering block (used by Deployment / StatefulSet).
Render type and rollingUpdate separately: Helm's deep merge leaves the default rollingUpdate
when a user changes type to Recreate|OnDelete, and the API server rejects that combination
(covered by a CI regression test).
Call: include "dockerhelm.rolloutStrategy" .Values.workload.strategy
Returns a block beginning with type:; the caller supplies the strategy:/updateStrategy: header and nindent.
*/}}
{{- define "dockerhelm.rolloutStrategy" -}}
{{- $st := . | default dict -}}
type: {{ $st.type | default "RollingUpdate" }}
{{- if eq ($st.type | default "RollingUpdate") "RollingUpdate" }}
{{- with $st.rollingUpdate }}
rollingUpdate:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart name + version label.
*/}}
{{- define "dockerhelm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Common labels (component is determined by workload.kind + user commonLabels).
Output one merged map where standard chart keys (including selector keys) always win.
This prevents duplicate YAML keys when commonLabels collides with a key, because
last-wins behavior could break selector matching.
*/}}
{{- define "dockerhelm.labels" -}}
{{- $lbl := dict
  "helm.sh/chart" (include "dockerhelm.chart" .)
  "app.kubernetes.io/name" (include "dockerhelm.name" .)
  "app.kubernetes.io/instance" .Release.Name
  "app.kubernetes.io/managed-by" .Release.Service
  "app.kubernetes.io/component" (.Values.workload.kind | lower) -}}
{{- with .Chart.AppVersion -}}
{{- $_ := set $lbl "app.kubernetes.io/version" (. | toString) -}}
{{- end -}}
{{- toYaml (merge $lbl (.Values.commonLabels | default dict)) -}}
{{- end }}

{{/*
Selector labels (shared by Deployment/StatefulSet; immutable because changing them replaces the workload)
*/}}
{{- define "dockerhelm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "dockerhelm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Resource-level annotations: commonAnnotations + resource-specific annotations (the latter take precedence).
Call: include "dockerhelm.annotations" (dict "root" $ "extra" .Values.service.annotations)
Returns YAML map contents or an empty string; callers absorb it with with.
merge mutates its first argument, so always deepCopy and never pass a map from .Values directly.
*/}}
{{- define "dockerhelm.annotations" -}}
{{- $merged := merge (deepCopy (.extra | default dict)) (.root.Values.commonAnnotations | default dict) -}}
{{- with $merged -}}
{{- toYaml . -}}
{{- end -}}
{{- end }}

{{/*
ServiceAccount name to use
*/}}
{{- define "dockerhelm.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "dockerhelm.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end }}

{{/*
Pod-spec ServiceAccount fields, shared by the main pod and job pods.
Hook pods never reference the chart-created ServiceAccount: pre-install hooks run before any release
resource exists, so the pod would never be created. They use an external one (serviceAccount.create=false
+ name) or the namespace default without a token.
Call: include "dockerhelm.serviceAccountFields" (dict "root" $ "hook" <non-empty when a Helm hook>)
*/}}
{{- define "dockerhelm.serviceAccountFields" -}}
{{- $sa := .root.Values.serviceAccount -}}
{{- $use := or $sa.create $sa.name -}}
{{- $automount := $sa.automount -}}
{{- if .hook -}}
{{- $use = and (not $sa.create) (ne ($sa.name | default "") "") -}}
{{- $automount = and $use $sa.automount -}}
{{- end -}}
{{- if $use -}}
serviceAccountName: {{ include "dockerhelm.serviceAccountName" .root }}
{{ end -}}
automountServiceAccountToken: {{ $automount }}
{{- end }}

{{/*
Image reference: digest takes precedence (repo@sha256:...); otherwise use repo:tag,
falling back to latest when tag is empty. repository is required because the generic chart
has no default image; fail fast during Helm rendering instead of producing an unusable manifest.
*/}}
{{- define "dockerhelm.imageRef" -}}
{{- if not .Values.image.repository -}}
{{- fail "image.repository is required (use your project's image, for example ghcr.io/acme/myapp)" -}}
{{- end -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default "latest") -}}
{{- end -}}
{{- end }}

{{/*
imagePullPolicy shared by the main container and job containers (they run the same image).
When pullPolicy is empty, select from the effective reference: digest or non-latest tag → IfNotPresent;
effective tag latest (fallback, explicit latest, or tag set to null) → Always.
IfNotPresent+latest would pin nodes to a stale cached image.
*/}}
{{- define "dockerhelm.imagePullPolicy" -}}
{{- $autoPolicy := "IfNotPresent" -}}
{{- if and (not .Values.image.digest) (eq (.Values.image.tag | default "latest") "latest") -}}
{{- $autoPolicy = "Always" -}}
{{- end -}}
{{- .Values.image.pullPolicy | default $autoPolicy -}}
{{- end }}

{{/*
imagePullSecrets: returns a complete YAML block ("imagePullSecrets:\n  - name: ...") or nothing.
  1) Explicit image.pullSecrets take precedence.
  2) Otherwise, exactly match the repository registry host (before the first /) against
     privateRegistries → inject image.pullSecretName.
Use exact matching rather than prefix matching to prevent look-alike domains such as
registry.example.com.evil.com from obtaining credentials, and to avoid invalid YAML from
duplicate output blocks. Callers use `{{- $ips := include ... | trim }}` + `{{ if $ips }}`
to absorb whitespace.
*/}}
{{- define "dockerhelm.imagePullSecrets" -}}
{{- if .Values.image.pullSecrets -}}
imagePullSecrets:
{{ toYaml .Values.image.pullSecrets | indent 2 -}}
{{- else -}}
{{- $registry := first (splitList "/" .Values.image.repository) -}}
{{- if has $registry .Values.image.privateRegistries -}}
imagePullSecrets:
  - name: {{ .Values.image.pullSecretName }}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Pod template annotations (checksum + commonAnnotations + user pod.annotations).
Returns YAML map contents; callers render it with `{{- with include ... }}` and nindent.
The checksum hashes only user data (data/stringData after tpl rendering), not the entire
manifest. Otherwise a chart version bump would roll every pod and distort rollOnChange semantics.
*/}}
{{- define "dockerhelm.podAnnotations" -}}
{{- $a := dict -}}
{{- if and .Values.configMap.create .Values.configMap.rollOnChange -}}
{{- $_ := set $a "checksum/configmap" (tpl (toYaml .Values.configMap.data) . | sha256sum) -}}
{{- end -}}
{{- if and .Values.secret.create .Values.secret.rollOnChange -}}
{{- $_ := set $a "checksum/secret" (printf "%s\n%s" (toYaml .Values.secret.data) (tpl (toYaml .Values.secret.stringData) .) | sha256sum) -}}
{{- end -}}
{{- $merged := merge (deepCopy (.Values.pod.annotations | default dict)) (.Values.commonAnnotations | default dict) $a -}}
{{- with $merged -}}
{{- toYaml . -}}
{{- end -}}
{{- end }}

{{/*
Pod template labels (selector labels + commonLabels + user-defined labels).
Merge into one map where selector keys always win. If a user collision produced duplicate keys,
YAML last-wins behavior could make the selector and template labels disagree, causing the API
server to reject the entire workload.
*/}}
{{- define "dockerhelm.podLabels" -}}
{{- $lbl := dict
  "app.kubernetes.io/name" (include "dockerhelm.name" .)
  "app.kubernetes.io/instance" .Release.Name -}}
{{- toYaml (merge $lbl (.Values.pod.labels | default dict) (.Values.commonLabels | default dict)) -}}
{{- end }}

{{/*
Default podAntiAffinity (used only when Values.affinity is not customized).
Returns a YAML block beginning with `podAntiAffinity:` (without the outer affinity:).
*/}}
{{- define "dockerhelm.podAntiAffinity" -}}
podAntiAffinity:
  {{- if eq .Values.podAntiAffinity.type "hard" }}
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          {{- include "dockerhelm.selectorLabels" . | nindent 10 }}
      topologyKey: {{ .Values.podAntiAffinity.topologyKey }}
  {{- else }}
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchLabels:
            {{- include "dockerhelm.selectorLabels" . | nindent 12 }}
        topologyKey: {{ .Values.podAntiAffinity.topologyKey }}
  {{- end }}
{{- end }}

{{/*
Complete topologySpreadConstraints block (including the header, expanded from the topologyKeys array).
The enabled check lives in the helper: return nothing when disabled or when topologyKeys is empty.
Callers use `{{- with include ... }}{{ . }}{{- end }}` to absorb whitespace (the same contract as affinity).
*/}}
{{- define "dockerhelm.topologySpread" -}}
{{- /* default dict fallback: treat a user setting the entire block to null (Helm removes the key) as disabled, not a nil crash */ -}}
{{- $tsc := .Values.topologySpreadConstraints | default dict -}}
{{- if and $tsc.enabled $tsc.topologyKeys -}}
topologySpreadConstraints:
{{- range $tsc.topologyKeys }}
  - maxSkew: {{ $tsc.maxSkew }}
    topologyKey: {{ . }}
    whenUnsatisfiable: {{ $tsc.whenUnsatisfiable }}
    labelSelector:
      matchLabels:
        {{- include "dockerhelm.selectorLabels" $ | nindent 8 }}
{{- end }}
{{- end -}}
{{- end }}

{{/*
Render one unified affinity block:
  Non-empty Values.affinity → fully user-defined
  Otherwise → include the default podAntiAffinity when enabled
Returns a complete block beginning with `affinity:` or nothing.
*/}}
{{- define "dockerhelm.affinity" -}}
{{- if .Values.affinity -}}
affinity:
  {{- toYaml .Values.affinity | nindent 2 }}
{{- else if ((.Values.podAntiAffinity | default dict).enabled) -}}
affinity:
  {{- include "dockerhelm.podAntiAffinity" . | nindent 2 }}
{{- end -}}
{{- end }}

{{/*
Whether a PDB will be created (shared condition for pdb.yaml and NOTES.txt).
Do not create a PDB for one replica, or node maintenance can block because no pod is evictable.
When HPA is enabled, use minReplicas to estimate the worst-case replica count. Using maxReplicas
could deadlock a drain after scaling down to one replica, so stay conservative (no PDB when
minReplicas=1; NOTES tells users to raise minReplicas).
Returns a non-empty string when the PDB will be created.
*/}}
{{- define "dockerhelm.pdbWillCreate" -}}
{{- if ((.Values.podDisruptionBudget | default dict).enabled) -}}
{{- $effective := ternary (int .Values.autoscaling.minReplicas) (int .Values.workload.replicas) .Values.autoscaling.enabled -}}
{{- if gt $effective 1 -}}true{{- end -}}
{{- end -}}
{{- end }}

{{/*
Effective PDB budget field (shared condition for pdb.yaml and NOTES.txt).
Choose minAvailable or maxUnavailable (minAvailable takes precedence when both are set).
0 is valid (freezes eviction), so check for nil/empty string rather than truthiness.
Returns one line, `minAvailable: X` / `maxUnavailable: X`, or nothing.
*/}}
{{- define "dockerhelm.pdbBudget" -}}
{{- $pdb := .Values.podDisruptionBudget -}}
{{- $minSet := and (not (kindIs "invalid" $pdb.minAvailable)) (ne (toString $pdb.minAvailable) "") -}}
{{- $maxSet := and (not (kindIs "invalid" $pdb.maxUnavailable)) (ne (toString $pdb.maxUnavailable) "") -}}
{{- if $minSet -}}
minAvailable: {{ $pdb.minAvailable }}
{{- else if $maxSet -}}
maxUnavailable: {{ $pdb.maxUnavailable }}
{{- end -}}
{{- end }}

{{/*
Container lifecycle (native Kubernetes fields, with three guards).
Kubernetes allows exactly one handler (exec / httpGet / tcpSocket / sleep) per hook, but Helm deep-merges
user values with the chart default preStop.sleep, so a user's own preStop handler arrives next to that sleep.
  1) preStop: a sleep next to another handler is the residue of the chart default → drop it
     (same idea as rolloutStrategy dropping a residual rollingUpdate).
  2) Two or more handlers still left on one hook were written by the user → fail with guidance.
  3) The native sleep action is on by default only from Kubernetes 1.30 (PodLifecycleSleepAction beta);
     older clusters get the equivalent exec "sleep N" instead (that path needs /bin/sh in the image).
Call: include "dockerhelm.lifecycle" (dict "root" $ "lc" <lifecycle values> "name" <container name>)
Returns YAML map contents or an empty string; callers absorb it with with.
*/}}
{{- define "dockerhelm.lifecycle" -}}
{{- $lc := deepCopy (.lc | default dict) -}}
{{- $native := semverCompare ">=1.30-0" .root.Capabilities.KubeVersion.Version -}}
{{- range $hook := list "postStart" "preStop" -}}
{{- $h := index $lc $hook -}}
{{- if $h -}}
{{- $set := list -}}
{{- range $t := list "exec" "httpGet" "tcpSocket" "sleep" -}}
{{- if hasKey $h $t -}}
{{- /* Helm keeps a user null when the default has no such key (e.g. exec: null after the default became sleep); drop it */ -}}
{{- if kindIs "invalid" (index $h $t) }}{{ $_ := unset $h $t }}{{ else }}{{ $set = append $set $t }}{{ end -}}
{{- end -}}
{{- end -}}
{{- if and (eq $hook "preStop") (has "sleep" $set) (gt (len $set) 1) -}}
{{- $_ := unset $h "sleep" -}}
{{- $set = without $set "sleep" -}}
{{- end -}}
{{- if gt (len $set) 1 -}}
{{- fail (printf "container %q lifecycle.%s sets %d handlers (%s), but Kubernetes allows exactly one; set the unused ones to null (an empty map does not remove a key under Helm's deep merge)" $.name $hook (len $set) (join ", " $set)) -}}
{{- end -}}
{{- if and (has "sleep" $set) (not $native) -}}
{{- $seconds := required (printf "container %q lifecycle.%s.sleep.seconds is required" $.name $hook) $h.sleep.seconds -}}
{{- $_ := set $h "exec" (dict "command" (list "/bin/sh" "-c" (printf "sleep %v" $seconds))) -}}
{{- $_ := unset $h "sleep" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- with $lc -}}
{{- toYaml . -}}
{{- end -}}
{{- end }}
