{{- define "runtime.image" -}}
{{ .Values.image.registry }}/{{ .repository }}:{{ .tag }}
{{- end }}
