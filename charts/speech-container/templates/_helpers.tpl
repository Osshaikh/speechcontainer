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

{{/*
  Version of the running image: the x.y.z prefix of image.tag, falling back to
  the chart appVersion when the tag has no version prefix.
*/}}
{{- define "speech-container.version" -}}
{{- $version := regexFind "^[0-9]+\\.[0-9]+\\.[0-9]+" (.Values.image.tag | toString) -}}
{{- default .Chart.AppVersion $version -}}
{{- end -}}

{{- define "speech-container.labels" -}}
app.kubernetes.io/name: {{ include "speech-container.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ include "speech-container.version" . | quote }}
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

{{/*
  Full image reference. image.tag is required (examples/stt-other.yaml and
  tts-other.yaml leave it empty on purpose), and an MCR-style tag must match
  the mode: TTS voice tags end in "neural", STT tags don't.
*/}}
{{- define "speech-container.image.full" -}}
{{- $tag := .Values.image.tag -}}
{{- if not $tag -}}
{{- if eq .Values.mode "tts" -}}
{{- fail "image.tag is required: pass this language's voice image, --set image.tag=<version>-amd64-<locale>-<voice>neural (e.g. 4.9.0-amd64-mr-in-aarohineural). Tags: https://mcr.microsoft.com/product/azure-cognitive-services/speechservices/neural-text-to-speech/tags" -}}
{{- else -}}
{{- fail "image.tag is required: pass this language's STT image, --set image.tag=<version>-amd64-<locale> (e.g. 5.3.0-amd64-mr-in). Tags: https://mcr.microsoft.com/product/azure-cognitive-services/speechservices/speech-to-text/tags" -}}
{{- end -}}
{{- end -}}
{{- if regexMatch "^[0-9]+\\.[0-9]+\\.[0-9]+.*-amd64-" $tag -}}
{{- $isVoice := contains "neural" (lower $tag) -}}
{{- if and (eq .Values.mode "stt") $isVoice -}}
{{- fail (printf "image.tag %q is a TTS voice image, but this release has mode: stt. Use an STT tag (<version>-amd64-<locale>, e.g. 5.3.0-amd64-mr-in), or install the voice with examples/tts-other.yaml" $tag) -}}
{{- else if and (eq .Values.mode "tts") (not $isVoice) -}}
{{- fail (printf "image.tag %q is an STT image, but this release has mode: tts. Use a voice tag (<version>-amd64-<locale>-<voice>neural, e.g. 4.9.0-amd64-mr-in-aarohineural), or install it with examples/stt-other.yaml" $tag) -}}
{{- end -}}
{{- end -}}
{{ .Values.image.registry }}/{{ include "speech-container.image.repository" . }}:{{ $tag }}
{{- end -}}

{{/*
  Tolerations: user-supplied list plus, when nodePool is set, a toleration for
  the <nodePoolKey>=<nodePool>:NoSchedule taint.
*/}}
{{- define "speech-container.tolerations" -}}
{{- $tolerations := list -}}
{{- with .Values.tolerations -}}
{{- $tolerations = concat $tolerations . -}}
{{- end -}}
{{- with .Values.nodePool -}}
{{- $tolerations = append $tolerations (dict "key" (required "nodePoolKey is required when nodePool is set" $.Values.nodePoolKey) "operator" "Equal" "value" . "effect" "NoSchedule") -}}
{{- end -}}
{{- with $tolerations -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}

{{/*
  Affinity: an explicit .Values.affinity wins; otherwise nodePool produces a
  node affinity for nodes labelled <nodePoolKey>=<nodePool>, preferred (soft)
  or required depending on .Values.nodePoolAffinity.
*/}}
{{- define "speech-container.affinity" -}}
{{- if .Values.affinity -}}
{{- toYaml .Values.affinity -}}
{{- else if .Values.nodePool -}}
{{- if eq .Values.nodePoolAffinity "required" -}}
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
      - matchExpressions:
          - key: {{ .Values.nodePoolKey | quote }}
            operator: In
            values:
              - {{ .Values.nodePool | quote }}
{{- else if eq .Values.nodePoolAffinity "preferred" -}}
nodeAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      preference:
        matchExpressions:
          - key: {{ .Values.nodePoolKey | quote }}
            operator: In
            values:
              - {{ .Values.nodePool | quote }}
{{- else -}}
{{- fail (printf "nodePoolAffinity must be 'preferred' or 'required', got %q" .Values.nodePoolAffinity) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
  Topology spread: explicit .Values.topologySpreadConstraints win; otherwise a
  single constraint spreading this release's pods across .topologySpread.topologyKey.
*/}}
{{- define "speech-container.topologySpreadConstraints" -}}
{{- if .Values.topologySpreadConstraints -}}
{{- toYaml .Values.topologySpreadConstraints -}}
{{- else if .Values.topologySpread.enabled -}}
- maxSkew: {{ .Values.topologySpread.maxSkew }}
  topologyKey: {{ .Values.topologySpread.topologyKey }}
  whenUnsatisfiable: {{ .Values.topologySpread.whenUnsatisfiable }}
  labelSelector:
    matchLabels: {{- include "speech-container.selectorLabels" . | nindent 6 }}
{{- end -}}
{{- end -}}

{{/*
  Image pull secrets from image.pullSecrets and the top-level imagePullSecrets alias.
*/}}
{{- define "speech-container.imagePullSecrets" -}}
{{- $secrets := concat (.Values.image.pullSecrets | default list) (.Values.imagePullSecrets | default list) | uniq -}}
{{- with $secrets -}}
{{- toYaml . -}}
{{- end -}}
{{- end -}}

{{/*
  Name of the SecretProviderClass used for the Key Vault CSI volume.
*/}}
{{- define "speech-container.secretProviderClassName" -}}
{{- default (include "speech-container.fullname" .) .Values.secretProviderClass.name -}}
{{- end -}}

{{/*
  True when pods should use Microsoft Entra Workload ID for Key Vault access.
*/}}
{{- define "speech-container.useWorkloadIdentity" -}}
{{- if and .Values.secretProviderClass.enabled (eq .Values.secretProviderClass.identity "workload") -}}
true
{{- end -}}
{{- end -}}

{{- define "speech-container.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "speech-container.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
