{{- define "ocudu.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ocudu.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "ocudu.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "ocudu.labels" -}}
app.kubernetes.io/name: {{ include "ocudu.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "ocudu.cuName" -}}{{ printf "%s-cu" .Release.Name }}{{- end -}}
{{- define "ocudu.duName" -}}{{ printf "%s-du" .Release.Name }}{{- end -}}
{{- define "ocudu.cuService" -}}
{{- default (include "ocudu.cuName" .) .Values.f1.cuServiceName -}}
{{- end -}}
