{{/*
Chart name, truncated to 63 chars.
*/}}
{{- define "paperless-ngx.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Uses fullnameOverride, or release-chart combo.
*/}}
{{- define "paperless-ngx.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "paperless-ngx.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{ include "paperless-ngx.selectorLabels" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "paperless-ngx.selectorLabels" -}}
app.kubernetes.io/name: {{ include "paperless-ngx.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* ---- PostgreSQL helpers ---- */}}

{{- define "paperless-ngx.postgresql.clusterName" -}}
{{- printf "%s-postgresql" (include "paperless-ngx.fullname" .) }}
{{- end }}

{{/*
Name of the secret that holds DB credentials.
CNPG auto-generates <cluster>-app; users may override via existingSecret.
*/}}
{{- define "paperless-ngx.postgresql.secretName" -}}
{{- if .Values.postgresql.existingSecret.name }}
{{- .Values.postgresql.existingSecret.name }}
{{- else }}
{{- printf "%s-app" (include "paperless-ngx.postgresql.clusterName" .) }}
{{- end }}
{{- end }}

{{- define "paperless-ngx.postgresql.host" -}}
{{- printf "%s-rw" (include "paperless-ngx.postgresql.clusterName" .) }}
{{- end }}

{{/* ---- Redis helpers ---- */}}

{{/*
Redis auth secret name. If the subchart's existingSecret is set, use it;
otherwise the redis-ha subchart auto-generates one named <release>-redis.
*/}}
{{- define "paperless-ngx.redis.secretName" -}}
{{- if .Values.redis.existingSecret }}
{{- .Values.redis.existingSecret }}
{{- else }}
{{- printf "%s-redis" .Release.Name }}
{{- end }}
{{- end }}

{{- define "paperless-ngx.redis.secretKey" -}}
{{- .Values.redis.authKey | default "auth" }}
{{- end }}

{{/*
Redis host. When haproxy is enabled, use the haproxy service; otherwise
connect to the first server pod via the headless service.
*/}}
{{- define "paperless-ngx.redis.host" -}}
{{- if .Values.redis.haproxy.enabled }}
{{- printf "%s-redis-haproxy" .Release.Name }}
{{- else }}
{{- printf "%s-redis" .Release.Name }}
{{- end }}
{{- end }}

{{/* ---- Component name helpers ---- */}}

{{- define "paperless-ngx.gotenberg.fullname" -}}
{{- printf "%s-gotenberg" (include "paperless-ngx.fullname" .) }}
{{- end }}

{{- define "paperless-ngx.tika.fullname" -}}
{{- printf "%s-tika" (include "paperless-ngx.fullname" .) }}
{{- end }}

{{- define "paperless-ngx.paperlessAi.fullname" -}}
{{- printf "%s-paperless-ai" (include "paperless-ngx.fullname" .) }}
{{- end }}

{{- define "paperless-ngx.paperlessGpt.fullname" -}}
{{- printf "%s-paperless-gpt" (include "paperless-ngx.fullname" .) }}
{{- end }}
