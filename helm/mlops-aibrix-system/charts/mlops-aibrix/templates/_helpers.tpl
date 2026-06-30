{{/*
  Multi-cloud model weight download helpers.
  Dispatches to aws s3 sync / gcloud storage rsync / azcopy based on global.cloud.
  Same pattern as the vllm-inference chart — kept consistent so ops teams only
  need to understand one download idiom across all model charts.
*/}}

{{- define "modelCache.downloadScript.aws" -}}
{{- $bucket := .bucket -}}
{{- $path   := .path -}}
{{- $dest   := .dest -}}
set -e
echo "Syncing s3://{{ $bucket }}/{{ $path }}/ → {{ $dest }}"
aws s3 sync "s3://{{ $bucket }}/{{ $path }}/" "{{ $dest }}/"
echo "Done. Contents:"; ls -la "{{ $dest }}/"
{{- end }}

{{- define "modelCache.downloadScript.gcp" -}}
{{- $bucket := .bucket -}}
{{- $path   := .path -}}
{{- $dest   := .dest -}}
set -e
gcloud storage rsync -r "gs://{{ $bucket }}/{{ $path }}/" "{{ $dest }}/"
{{- end }}

{{- define "modelCache.downloadScript.az" -}}
{{- $account   := .account -}}
{{- $container := .container -}}
{{- $path      := .path -}}
{{- $dest      := .dest -}}
set -e
export AZCOPY_AUTO_LOGIN_TYPE=WORKLOAD
mkdir -p "{{ $dest }}"
for attempt in 1 2 3; do
  echo "azcopy sync attempt $attempt/3"
  if azcopy sync "https://{{ $account }}.blob.core.windows.net/{{ $container }}/{{ $path }}" "{{ $dest }}" --recursive=true; then
    echo "Succeeded"; break
  fi
  [ "$attempt" -eq 3 ] && { echo "Failed after 3 attempts"; exit 1; }
  echo "Retry in 60s..."; sleep 60
done
{{- end }}

{{- define "modelCache.qwen.downloadScript" -}}
{{- $v := .Values -}}
{{- if eq $v.global.cloud "aws" -}}
  {{- include "modelCache.downloadScript.aws" (dict "bucket" $v.model_storage.model_storage_location "path" $v.model_storage.qwen.model_path "dest" (printf "/zm-model-cache/%s" $v.model_storage.qwen.model_path)) }}
{{- else if eq $v.global.cloud "gcp" -}}
  {{- include "modelCache.downloadScript.gcp" (dict "bucket" $v.model_storage.model_storage_location "path" $v.model_storage.qwen.model_path "dest" (printf "/zm-model-cache/%s" $v.model_storage.qwen.model_path)) }}
{{- else if eq $v.global.cloud "az" -}}
  {{- include "modelCache.downloadScript.az" (dict "account" $v.global.storage_account_name "container" $v.model_storage.model_storage_location "path" $v.model_storage.qwen.model_path "dest" (printf "/zm-model-cache/%s" $v.model_storage.qwen.model_path)) }}
{{- end -}}
{{- end }}

{{- define "modelCache.qwen.lora.downloadScript" -}}
{{- $v := .Values -}}
{{- if $v.model_storage.qwen.lora_adapter_path -}}
{{- if eq $v.global.cloud "aws" -}}
  {{- include "modelCache.downloadScript.aws" (dict "bucket" $v.model_storage.model_storage_location "path" $v.model_storage.qwen.lora_adapter_path "dest" "/lora-adapter-cache") }}
{{- else if eq $v.global.cloud "gcp" -}}
  {{- include "modelCache.downloadScript.gcp" (dict "bucket" $v.model_storage.model_storage_location "path" $v.model_storage.qwen.lora_adapter_path "dest" "/lora-adapter-cache") }}
{{- else if eq $v.global.cloud "az" -}}
  {{- include "modelCache.downloadScript.az" (dict "account" $v.global.storage_account_name "container" $v.model_storage.model_storage_location "path" $v.model_storage.qwen.lora_adapter_path "dest" "/lora-adapter-cache") }}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "modelCache.llama.downloadScript" -}}
{{- $v := .Values -}}
{{- if eq $v.global.cloud "aws" -}}
  {{- include "modelCache.downloadScript.aws" (dict "bucket" $v.model_storage.model_storage_location "path" $v.model_storage.llama.model_path "dest" (printf "/zm-model-cache/%s" $v.model_storage.llama.model_path)) }}
{{- else if eq $v.global.cloud "gcp" -}}
  {{- include "modelCache.downloadScript.gcp" (dict "bucket" $v.model_storage.model_storage_location "path" $v.model_storage.llama.model_path "dest" (printf "/zm-model-cache/%s" $v.model_storage.llama.model_path)) }}
{{- else if eq $v.global.cloud "az" -}}
  {{- include "modelCache.downloadScript.az" (dict "account" $v.global.storage_account_name "container" $v.model_storage.model_storage_location "path" $v.model_storage.llama.model_path "dest" (printf "/zm-model-cache/%s" $v.model_storage.llama.model_path)) }}
{{- end -}}
{{- end }}

{{/*  Cloud-specific pod labels (Azure Workload Identity)  */}}
{{- define "mlops.cloudPodLabels" -}}
{{- if eq .Values.global.cloud "az" -}}
azure.workload.identity/use: "true"
{{- end -}}
{{- end }}

{{/*  Resolve model image: per-model override → vllm.image fallback  */}}
{{- define "mlops.modelImage" -}}
{{- $m := .model -}}
{{- $v := .Values -}}
{{- $img := $m.image | default dict -}}
{{ ($img.registry   | default $v.vllm.image.registry) }}/{{ ($img.repository | default $v.vllm.image.repository) }}:{{ ($img.tag | default $v.vllm.image.tag) }}
{{- end }}
