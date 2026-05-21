{{/*
  speech-container helpers
*/}}

{{- define "speech-container.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "speech-container.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "speech-container.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "speech-container.labels" -}}
app.kubernetes.io/name: {{ include "speech-container.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
speech.azure.com/mode: {{ .Values.mode | quote }}
{{- end -}}

{{- define "speech-container.selectorLabels" -}}
app.kubernetes.io/name: {{ include "speech-container.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
  Derive the image repository from `mode` if not explicitly set.
*/}}
{{- define "speech-container.image.repository" -}}
{{- if .Values.image.repository -}}
{{- .Values.image.repository -}}
{{- else if eq .Values.mode "stt" -}}
azure-cognitive-services/speechservices/speech-to-text
{{- else if eq .Values.mode "tts" -}}
azure-cognitive-services/speechservices/neural-text-to-speech
{{- else -}}
{{- fail (printf "invalid mode: %s — must be 'stt' or 'tts'" .Values.mode) -}}
{{- end -}}
{{- end -}}

{{- define "speech-container.image.full" -}}
{{ .Values.image.registry }}/{{ include "speech-container.image.repository" . }}:{{ .Values.image.tag }}
{{- end -}}

{{- define "speech-container.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "speech-container.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
