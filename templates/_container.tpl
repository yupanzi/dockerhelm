{{/*
Main container spec (passes through native Kubernetes fields without implicit mounts).
Volumes are created by _podSpec.tpl, while users explicitly declare mount points in
container.volumeMounts, keeping creation and use decoupled. Reference-name convention
for chart-created volumes:
  config           ConfigMap (exists when configMap.create=true)
  secret           Secret (exists when secret.create=true)
  {{ .Values.persistence.name }}   PVC (exists when persistence.enabled=true)
env / envFrom are rendered with tpl, so values may use expressions such as {{ include "dockerhelm.fullname" . }}.
*/}}
{{- define "dockerhelm.container" -}}
- name: {{ .Values.container.name | default .Chart.Name }}
  image: {{ include "dockerhelm.imageRef" . | quote }}
  {{- /* When pullPolicy is empty, select from the effective reference: digest or non-latest tag → IfNotPresent;
     effective tag latest (fallback, explicit latest, or tag set to null) → Always.
     IfNotPresent+latest would pin nodes to a stale cached image. */}}
  {{- $autoPolicy := "IfNotPresent" }}
  {{- if and (not .Values.image.digest) (eq (.Values.image.tag | default "latest") "latest") }}
  {{- $autoPolicy = "Always" }}
  {{- end }}
  imagePullPolicy: {{ .Values.image.pullPolicy | default $autoPolicy }}
  {{- with .Values.container.command }}
  command:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.container.args }}
  args:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.container.workingDir }}
  workingDir: {{ . | quote }}
  {{- end }}
  {{- with .Values.container.ports }}
  ports:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.container.env }}
  env:
    {{- tpl (toYaml .) $ | nindent 4 }}
  {{- end }}
  {{- with .Values.container.envFrom }}
  envFrom:
    {{- tpl (toYaml .) $ | nindent 4 }}
  {{- end }}
  {{- with .Values.container.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.container.securityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.container.livenessProbe }}
  livenessProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.container.readinessProbe }}
  readinessProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.container.startupProbe }}
  startupProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.container.lifecycle }}
  lifecycle:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.container.volumeMounts }}
  volumeMounts:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
