{{/*
Shared PodSpec fragment (used by Deployment / StatefulSet).
Outputs spec contents only (without metadata/selector); callers provide the outer structure.
Volumes are created automatically for configMap.create / secret.create / persistence.enabled+existingClaim.
StatefulSet PVCs are injected through volumeClaimTemplates and are not duplicated here.
*/}}
{{- define "dockerhelm.podSpec" -}}
{{- $ips := include "dockerhelm.imagePullSecrets" . | trim -}}
{{- if $ips }}
{{ $ips }}
{{- end }}
{{- include "dockerhelm.serviceAccountFields" (dict "root" .) | nindent 0 }}
terminationGracePeriodSeconds: {{ .Values.workload.terminationGracePeriodSeconds }}
{{- with .Values.pod.securityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.pod.priorityClassName }}
priorityClassName: {{ . | quote }}
{{- end }}
{{- with .Values.pod.hostAliases }}
hostAliases:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.pod.dnsPolicy }}
dnsPolicy: {{ . }}
{{- end }}
{{- with .Values.pod.dnsConfig }}
dnsConfig:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.initContainers }}
initContainers:
  {{- tpl (toYaml .) $ | nindent 2 }}
{{- end }}
containers:
  {{- include "dockerhelm.container" (dict "root" . "c" .Values.container "name" (.Values.container.name | default .Chart.Name)) | nindent 2 }}
  {{- with .Values.extraContainers }}
  {{- tpl (toYaml .) $ | nindent 2 }}
  {{- end }}
{{- $persistVolume := and .Values.persistence.enabled (or (ne .Values.workload.kind "StatefulSet") .Values.persistence.existingClaim) }}
{{- if or .Values.volumes .Values.configMap.create .Values.secret.create $persistVolume }}
volumes:
  {{- with .Values.volumes }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
  {{- if .Values.configMap.create }}
  - name: config
    configMap:
      name: {{ include "dockerhelm.configMapName" . }}
  {{- end }}
  {{- if .Values.secret.create }}
  - name: secret
    secret:
      secretName: {{ include "dockerhelm.secretName" . }}
  {{- end }}
  {{- if $persistVolume }}
  - name: {{ .Values.persistence.name }}
    persistentVolumeClaim:
      claimName: {{ .Values.persistence.existingClaim | default (include "dockerhelm.pvcName" .) }}
  {{- end }}
{{- end }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with include "dockerhelm.affinity" . }}
{{ . }}
{{- end }}
{{- with include "dockerhelm.topologySpread" . }}
{{ . }}
{{- end }}
{{- with .Values.pod.extraSpec }}
{{ toYaml . }}
{{- end }}
{{- end }}
