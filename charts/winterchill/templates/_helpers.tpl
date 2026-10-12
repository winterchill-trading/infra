{{- define "winterchill.labels" -}}
app.kubernetes.io/part-of: winterchill
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}

{{- define "winterchill.image" -}}
{{ .root.Values.imageRegistry }}/{{ .image.repository }}:{{ .image.tag }}
{{- end }}

{{/* Name of the Secret holding S3 credentials ("" when using the instance role). */}}
{{- define "winterchill.s3SecretName" -}}
{{- if .Values.s3.useInstanceRole -}}
{{- else if .Values.s3.existingSecret -}}
{{ .Values.s3.existingSecret }}
{{- else -}}
{{ .Release.Name }}-s3
{{- end -}}
{{- end }}

{{/* rclone S3 remote named `s3`, configured entirely from the environment. */}}
{{- define "winterchill.rcloneEnv" -}}
# Root filesystems are read-only: keep rclone's config and cache in /tmp.
- name: RCLONE_CONFIG
  value: /tmp/rclone.conf
- name: RCLONE_CACHE_DIR
  value: /tmp/rclone
- name: RCLONE_CONFIG_S3_TYPE
  value: s3
- name: RCLONE_CONFIG_S3_PROVIDER
  value: {{ .Values.s3.provider | quote }}
- name: RCLONE_CONFIG_S3_REGION
  value: {{ .Values.s3.region | quote }}
{{- with .Values.s3.endpoint }}
- name: RCLONE_CONFIG_S3_ENDPOINT
  value: {{ . | quote }}
{{- end }}
- name: RCLONE_CONFIG_S3_ENV_AUTH
  value: "true"
{{- with include "winterchill.s3SecretName" . }}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef: { name: {{ . }}, key: AWS_ACCESS_KEY_ID }
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef: { name: {{ . }}, key: AWS_SECRET_ACCESS_KEY }
{{- end }}
{{- end }}

{{/* s3:<bucket>[/<prefix>] */}}
{{- define "winterchill.s3Remote" -}}
s3:{{ .Values.s3.bucket }}{{ with .Values.s3.prefix }}/{{ trimSuffix "/" . }}{{ end }}
{{- end }}
