#!/usr/bin/env bash
# Local demo setup: kind cluster + local registry + full stack
# Requirements: kind, kubectl, helm, docker
set -euo pipefail

CLUSTER_NAME="mlops-local"
REGISTRY_NAME="kind-registry"
REGISTRY_PORT="5001"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

log() { echo -e "\033[1;34m[setup]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[ok]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

# --- Prerequisites check ---
for cmd in kind kubectl helm docker; do
  command -v "$cmd" &>/dev/null || err "$cmd not found. Install it first."
done
ok "Prerequisites satisfied"

# --- Local container registry (avoids DockerHub rate limits in kind) ---
if ! docker inspect "$REGISTRY_NAME" &>/dev/null; then
  log "Starting local registry on localhost:${REGISTRY_PORT}..."
  docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    --name "$REGISTRY_NAME" registry:2
fi
ok "Local registry running at localhost:${REGISTRY_PORT}"

# --- kind cluster ---
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  log "Cluster '${CLUSTER_NAME}' already exists, skipping creation"
else
  log "Creating kind cluster '${CLUSTER_NAME}'..."
  cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${REGISTRY_PORT}"]
      endpoint = ["http://${REGISTRY_NAME}:5000"]
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 8080
        protocol: TCP
      - containerPort: 443
        hostPort: 8443
        protocol: TCP
  - role: worker
    labels:
      node-type: gpu
      accelerator: nvidia-tesla-t4
EOF
fi

# Connect registry to kind network
if ! docker network inspect kind &>/dev/null | grep -q "$REGISTRY_NAME"; then
  docker network connect kind "$REGISTRY_NAME" 2>/dev/null || true
fi

kubectl config use-context "kind-${CLUSTER_NAME}"
ok "Cluster ready"

# --- Namespaces ---
log "Creating namespaces..."
kubectl apply -f "$ROOT_DIR/k8s/namespace.yaml"

# --- NGINX Ingress (kind-compatible) ---
log "Installing NGINX ingress controller..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.hostPort.enabled=true \
  --set controller.service.type=NodePort \
  --set controller.watchIngressWithoutClass=true \
  --wait --timeout=3m
ok "NGINX ingress ready"

# --- Prometheus + Grafana ---
log "Installing kube-prometheus-stack (Prometheus + Grafana)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f "$ROOT_DIR/k8s/monitoring/prometheus-values.yaml" \
  --set prometheus.prometheusSpec.storageSpec="" \
  --set grafana.persistence.enabled=false \
  --wait --timeout=5m
ok "Prometheus + Grafana ready"

# Apply Grafana dashboard ConfigMap
kubectl apply -f "$ROOT_DIR/k8s/monitoring/grafana-dashboard-configmap.yaml"

# --- KEDA ---
log "Installing KEDA..."
helm repo add kedacore https://kedacore.github.io/charts --force-update
helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace \
  --wait --timeout=3m
ok "KEDA ready"

# --- Build & push CPU vLLM image to local registry ---
log "Building CPU vLLM image (this takes a few minutes)..."
docker build \
  -f "$ROOT_DIR/docker/Dockerfile.cpu" \
  -t "localhost:${REGISTRY_PORT}/vllm-inference:local" \
  "$ROOT_DIR/docker/"
docker push "localhost:${REGISTRY_PORT}/vllm-inference:local"
ok "vLLM image pushed to local registry"

# --- Deploy vLLM ---
log "Deploying vLLM..."
# Patch the image reference for local use
kubectl apply -f "$ROOT_DIR/k8s/vllm/serviceaccount.yaml"
kubectl apply -f "$ROOT_DIR/k8s/vllm/service.yaml"
kubectl apply -f "$ROOT_DIR/k8s/vllm/ingress.yaml"

# Render deployment with local image + CPU flags
sed \
  -e "s|ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/vllm-inference:latest|localhost:${REGISTRY_PORT}/vllm-inference:local|g" \
  -e "s|node-type: gpu|node-type: worker|g" \
  "$ROOT_DIR/k8s/vllm/deployment.yaml" | kubectl apply -f -

kubectl apply -f "$ROOT_DIR/k8s/keda/scaledobject.yaml"

log "Waiting for vLLM pod (model download + load takes ~3-5 min)..."
kubectl rollout status deployment/vllm -n vllm --timeout=10m
ok "vLLM deployed"

# --- Summary ---
echo ""
echo "================================================"
ok "Local stack is up!"
echo ""
echo "  Endpoints (add to /etc/hosts: 127.0.0.1 vllm.local):"
echo "  vLLM API:   http://vllm.local:8080"
echo "  Grafana:    http://localhost:3000  (admin/changeme-in-production)"
echo ""
echo "  Port-forward shortcuts:"
echo "    kubectl port-forward -n vllm svc/vllm 8000:80"
echo "    kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
echo ""
echo "  Run smoke test:"
echo "    ./scripts/test-api.sh"
echo "================================================"
