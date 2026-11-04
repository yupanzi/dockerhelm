{{/*
Container spec (passes through native Kubernetes fields without implicit mounts), shared by the main
container (_podSpec.tpl) and job containers (_job.tpl); fields a job entry does not allow simply render nothing.
Volumes are created by _podSpec.tpl, while users explicitly declare mount points in
container.volumeMounts, keeping creation and use decoupled. Reference-name convention
for chart-created volumes:
  config           ConfigMap (exists when configMap.create=true)
  secret           Secret (exists when secret.create=true)
  {{ .Values.persistence.name }}   PVC (exists when persistence.enabled=true)
env / envFrom are rendered with tpl, so values may use expressions such as {{ include "dockerhelm.fullname" . }}.
Call: include "dockerhelm.container" (dict "root" $ "c" <container values> "name" <container name>)
*/}}
{{- define "dockerhelm.container" -}}
{{- $root := .root -}}
{{- $c := .c -}}
- name: {{ .name }}
  image: {{ include "dockerhelm.imageRef" $root | quote }}
  imagePullPolicy: {{ include "dockerhelm.imagePullPolicy" $root }}
  {{- with $c.command }}
  command:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $c.args }}
  args:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $c.workingDir }}
  workingDir: {{ . | quote }}
  {{- end }}
  {{- with $c.ports }}
  ports:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $c.env }}
  env:
    {{- tpl (toYaml .) $root | nindent 4 }}
  {{- end }}
  {{- with $c.envFrom }}
  envFrom:
    {{- tpl (toYaml .) $root | nindent 4 }}
  {{- end }}
  {{- with $c.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $c.securityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $c.livenessProbe }}
  livenessProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $c.readinessProbe }}
  readinessProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $c.startupProbe }}
  startupProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- /* Handler guards and the < 1.30 sleep fallback live in the dockerhelm.lifecycle helper */}}
  {{- with include "dockerhelm.lifecycle" (dict "root" $root "lc" $c.lifecycle "name" .name) }}
  lifecycle:
    {{- . | nindent 4 }}
  {{- end }}
  {{- with $c.volumeMounts }}
  volumeMounts:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
