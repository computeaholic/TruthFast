{{/*
Common labels for all ThreadForge resources
*/}}
{{- define "threadforge.labels" -}}
app.kubernetes.io/name: threadforge
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: Helm
{{- end -}}
