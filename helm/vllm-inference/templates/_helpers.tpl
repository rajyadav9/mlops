{{/*
  Model weight download helpers — mirrors the multi-cloud pattern from the apollo/zm-aibrix chart.
  Supports: aws (s3 sync) | gcp (gcloud storage rsync) | az (azcopy sync with workload identity).
  Retries 3 times with 60s back-off to handle transient storage throttling.
*/}}

{{- define "modelCache.downloadScript.aws" -}}
{{- $bucket := .bucket -}}
{{- $path := .path -}}
{{- $dest := .dest -}}
set -e
echo "Syncing s3://{{ $bucket }}/{{ $path }}/ → {{ $dest }}"
aws s3 sync "s3://{{ $bucket }}/{{ $path }}/" "{{ $dest }}/"
echo "Sync complete. Contents:"
ls -la "{{ $dest }}/"
{{- end }}

{{- define "modelCache.downloadScript.gcp" -}}
{{- $bucket := .bucket -}}
{{- $path := .path -}}
{{- $dest := .dest -}}
set -e
echo "Syncing gs://{{ $bucket }}/{{ $path }}/ → {{ $dest }}"
gcloud storage rsync -r "gs://{{ $bucket }}/{{ $path }}/" "{{ $dest }}/"
echo "Sync complete."
{{- end }}

{{- define "modelCache.downloadScript.az" -}}
{{- $account := .account -}}
{{- $container := .container -}}
{{- $path := .path -}}
{{- $dest := .dest -}}
set -e
export AZCOPY_AUTO_LOGIN_TYPE=WORKLOAD
mkdir -p "{{ $dest }}"
for attempt in 1 2 3; do
  echo "azcopy sync attempt $attempt/3"
  if azcopy sync \
    "https://{{ $account }}.blob.core.windows.net/{{ $container }}/{{ $path }}" \
    "{{ $dest }}" --recursive=true; then
    echo "azcopy sync succeeded"; break
  fi
  if [ "$attempt" -eq 3 ]; then echo "azcopy sync failed after 3 attempts"; exit 1; fi
  echo "Retrying in 60s..."; sleep 60
done
ls -la "{{ $dest }}/"
{{- end }}

{{/*
  modelCache.qwen.downloadScript — dispatches to the right cloud impl
*/}}
{{- define "modelCache.qwen.downloadScript" -}}
{{- $v := .Values -}}
{{- if eq $v.global.cloud "aws" -}}
{{- include "modelCache.downloadScript.aws" (dict
    "bucket" $v.model_storage.model_storage_location
    "path"   $v.model_storage.qwen.model_path
    "dest"   (printf "/zm-model-cache/%s" $v.model_storage.qwen.model_path)) }}
{{- else if eq $v.global.cloud "gcp" -}}
{{- include "modelCache.downloadScript.gcp" (dict
    "bucket" $v.model_storage.model_storage_location
    "path"   $v.model_storage.qwen.model_path
    "dest"   (printf "/zm-model-cache/%s" $v.model_storage.qwen.model_path)) }}
{{- else if eq $v.global.cloud "az" -}}
{{- include "modelCache.downloadScript.az" (dict
    "account"   $v.global.storage_account_name
    "container" $v.model_storage.model_storage_location
    "path"      $v.model_storage.qwen.model_path
    "dest"      (printf "/zm-model-cache/%s" $v.model_storage.qwen.model_path)) }}
{{- end -}}
{{- end }}

{{- define "modelCache.qwen.lora.downloadScript" -}}
{{- $v := .Values -}}
{{- if $v.model_storage.qwen.lora_adapter_path -}}
{{- if eq $v.global.cloud "aws" -}}
{{- include "modelCache.downloadScript.aws" (dict
    "bucket" $v.model_storage.model_storage_location
    "path"   $v.model_storage.qwen.lora_adapter_path
    "dest"   "/lora-adapter-cache") }}
{{- else if eq $v.global.cloud "gcp" -}}
{{- include "modelCache.downloadScript.gcp" (dict
    "bucket" $v.model_storage.model_storage_location
    "path"   $v.model_storage.qwen.lora_adapter_path
    "dest"   "/lora-adapter-cache") }}
{{- else if eq $v.global.cloud "az" -}}
{{- include "modelCache.downloadScript.az" (dict
    "account"   $v.global.storage_account_name
    "container" $v.model_storage.model_storage_location
    "path"      $v.model_storage.qwen.lora_adapter_path
    "dest"      "/lora-adapter-cache") }}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "modelCache.llama.downloadScript" -}}
{{- $v := .Values -}}
{{- if eq $v.global.cloud "aws" -}}
{{- include "modelCache.downloadScript.aws" (dict
    "bucket" $v.model_storage.model_storage_location
    "path"   $v.model_storage.llama.model_path
    "dest"   (printf "/zm-model-cache/%s" $v.model_storage.llama.model_path)) }}
{{- else if eq $v.global.cloud "gcp" -}}
{{- include "modelCache.downloadScript.gcp" (dict
    "bucket" $v.model_storage.model_storage_location
    "path"   $v.model_storage.llama.model_path
    "dest"   (printf "/zm-model-cache/%s" $v.model_storage.llama.model_path)) }}
{{- else if eq $v.global.cloud "az" -}}
{{- include "modelCache.downloadScript.az" (dict
    "account"   $v.global.storage_account_name
    "container" $v.model_storage.model_storage_location
    "path"      $v.model_storage.llama.model_path
    "dest"      (printf "/zm-model-cache/%s" $v.model_storage.llama.model_path)) }}
{{- end -}}
{{- end }}

{{/*
  Cloud-specific pod labels (e.g. Azure Workload Identity)
*/}}
{{- define "vllm.cloudPodLabels" -}}
{{- if eq .Values.global.cloud "az" -}}
azure.workload.identity/use: "true"
{{- end -}}
{{- end }}

{{/*
  Resolve model image — per-model override falls back to global vllm.image
*/}}
{{- define "vllm.image" -}}
{{- $model := .model -}}
{{- $v := .Values -}}
{{- $img := $model.image | default dict -}}
{{- $registry   := $img.registry   | default $v.vllm.image.registry -}}
{{- $repository := $img.repository | default $v.vllm.image.repository -}}
{{- $tag        := $img.tag        | default $v.vllm.image.tag -}}
{{ $registry }}/{{ $repository }}:{{ $tag }}
{{- end }}
