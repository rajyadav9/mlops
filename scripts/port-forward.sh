#!/usr/bin/env bash
# Open port-forwards for local access to all services.
# Run in a dedicated terminal; Ctrl-C to stop all.
set -euo pipefail

cleanup() {
  echo "Stopping port-forwards..."
  kill $(jobs -p) 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Starting port-forwards..."
kubectl port-forward -n vllm              svc/vllm                                   8000:80  &
kubectl port-forward -n monitoring        svc/kube-prometheus-stack-prometheus        9090:9090 &
kubectl port-forward -n monitoring        svc/kube-prometheus-stack-grafana           3000:80  &

echo ""
echo "  vLLM API  → http://localhost:8000"
echo "  Prometheus → http://localhost:9090"
echo "  Grafana    → http://localhost:3000  (admin / changeme-in-production)"
echo ""
echo "Press Ctrl-C to stop all port-forwards."
wait
