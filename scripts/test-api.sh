#!/usr/bin/env bash
# Smoke test for the vLLM OpenAI-compatible API
# Usage: ./scripts/test-api.sh [BASE_URL]
set -euo pipefail

BASE_URL="${1:-http://localhost:8000}"

log()  { echo -e "\033[1;34m[test]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[pass]\033[0m $*"; }
fail() { echo -e "\033[1;31m[fail]\033[0m $*" >&2; exit 1; }

log "Testing vLLM at ${BASE_URL}"

# --- Health check ---
log "GET /health"
HEALTH=$(curl -sf "${BASE_URL}/health" || fail "Health endpoint unreachable")
ok "Health: ${HEALTH}"

# --- Models list ---
log "GET /v1/models"
MODELS=$(curl -sf "${BASE_URL}/v1/models")
MODEL_ID=$(echo "$MODELS" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])")
ok "Model loaded: ${MODEL_ID}"

# --- Completions ---
log "POST /v1/completions"
RESPONSE=$(curl -sf "${BASE_URL}/v1/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL_ID}\",
    \"prompt\": \"The future of AI in banking is\",
    \"max_tokens\": 50,
    \"temperature\": 0.7
  }")

GENERATED=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['text'])")
ok "Completion: ...${GENERATED}"

# --- Chat completions ---
log "POST /v1/chat/completions"
CHAT=$(curl -sf "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL_ID}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}],
    \"max_tokens\": 30
  }")
CHAT_REPLY=$(echo "$CHAT" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])")
ok "Chat reply: ${CHAT_REPLY}"

# --- Metrics ---
log "GET /metrics (Prometheus)"
METRICS=$(curl -sf "${BASE_URL}/metrics")
for metric in "vllm:num_requests_running" "vllm:gpu_cache_usage_perc" "vllm:e2e_request_latency_seconds"; do
  if echo "$METRICS" | grep -q "$metric"; then
    ok "Metric exposed: ${metric}"
  else
    fail "Missing metric: ${metric}"
  fi
done

echo ""
ok "All checks passed!"
