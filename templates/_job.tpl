{{/*
Shared pieces for jobs.<key> (jobs.yaml) and cronJobs.<key> (cronjobs.yaml); what an entry inherits from
the main workload is documented in values.yaml. Every helper takes the same context:
  (dict "root" $ "key" $key "job" <entry> "kind" "Job"|"CronJob")
*/}}

{{/*
Resource name {fullname}-{key}. Fail instead of truncating: truncation can collide two keys.
CronJob max is 52 because the controller appends an 11-character suffix to each Job it creates.
*/}}
{{- define "dockerhelm.jobName" -}}
{{- $max := ternary 52 63 (eq .kind "CronJob") -}}
{{- $name := printf "%s-%s" (include "dockerhelm.fullname" .root) .key -}}
{{- if gt (len $name) $max -}}
{{- fail (printf "%s name %q exceeds %d characters; shorten the key or set fullnameOverride" .kind $name $max) -}}
{{- end -}}
{{- $name -}}
{{- end }}

{{- define "dockerhelm.jobComponent" -}}
{{- printf "%s-%s" (lower .kind) .key -}}
{{- end }}

{{/* Common labels with component replaced by "job-<key>" / "cronjob-<key>" */}}
{{- define "dockerhelm.jobLabels" -}}
{{- $lbl := include "dockerhelm.labels" .root | fromYaml -}}
{{- $_ := set $lbl "app.kubernetes.io/component" (include "dockerhelm.jobComponent" .) -}}
{{- toYaml $lbl -}}
{{- end }}

{{/* metadata of the Job / CronJob resource */}}
{{- define "dockerhelm.jobMetadata" -}}
name: {{ include "dockerhelm.jobName" . }}
labels:
  {{- include "dockerhelm.jobLabels" . | nindent 2 }}
{{- with include "dockerhelm.annotations" (dict "root" .root "extra" .job.annotations) }}
annotations:
  {{- . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Pod template of a Job (the value of `template:` in a Job spec).
- Pod labels never carry app.kubernetes.io/name, even through commonLabels / pod.labels: the main
  Service, PDB, anti-affinity and topology spread select on name+instance, so a running job pod would
  otherwise receive Service traffic and count against the PDB.
- restartPolicy is Never: podFailurePolicy requires it, and failed pods stay around for kubectl logs.
*/}}
{{- define "dockerhelm.jobPodTemplate" -}}
{{- $root := .root -}}
{{- $v := $root.Values -}}
{{- $pod := .job.pod | default dict -}}
{{- $c := deepCopy (.job.container | default dict) -}}
{{- if not $c.securityContext -}}
{{- $_ := set $c "securityContext" $v.container.securityContext -}}
{{- end -}}
{{- $labels := omit (merge (dict "app.kubernetes.io/instance" $root.Release.Name "app.kubernetes.io/component" (include "dockerhelm.jobComponent" .)) ($pod.labels | default dict) ($v.commonLabels | default dict)) "app.kubernetes.io/name" -}}
metadata:
  labels:
    {{- toYaml $labels | nindent 4 }}
  {{- with include "dockerhelm.annotations" (dict "root" $root "extra" $pod.annotations) }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
spec:
  restartPolicy: Never
  {{- $ips := include "dockerhelm.imagePullSecrets" $root | trim }}
  {{- if $ips }}
  {{- $ips | nindent 2 }}
  {{- end }}
  {{- include "dockerhelm.serviceAccountFields" (dict "root" $root "hook" (dig "annotations" "helm.sh/hook" "" .job)) | nindent 2 }}
  {{- with $pod.securityContext | default $v.pod.securityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .job.nodeSelector | default $v.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .job.tolerations | default $v.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    {{- include "dockerhelm.container" (dict "root" $root "c" $c "name" ($c.name | default .key)) | nindent 4 }}
  {{- with .job.volumes }}
  volumes:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $pod.extraSpec }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end }}
