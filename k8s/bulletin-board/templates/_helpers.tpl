{{/* Chart name. */}}
{{- define "bulletin-board.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified application name. */}}
{{- define "bulletin-board.fullname" -}}
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

{{/* Chart label. */}}
{{- define "bulletin-board.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Immutable selectors retained from the pre-Helm manifests. */}}
{{- define "bulletin-board.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bulletin-board.fullname" . }}
app.kubernetes.io/component: application
{{- end }}

{{/* Standard labels recommended by Helm. */}}
{{- define "bulletin-board.labels" -}}
helm.sh/chart: {{ include "bulletin-board.chart" . }}
{{ include "bulletin-board.selectorLabels" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "bulletin-board.configMapName" -}}
{{- printf "%s-config" (include "bulletin-board.fullname" .) }}
{{- end }}

{{- define "bulletin-board.migrationsConfigMapName" -}}
{{- printf "%s-migrations" (include "bulletin-board.fullname" .) }}
{{- end }}

{{- define "bulletin-board.secretName" -}}
{{- required "secret.existingSecret must be set" .Values.secret.existingSecret }}
{{- end }}
