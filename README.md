# vLLM Inference Service on EKS

Production-grade vLLM inference service with GPU-accelerated EKS, KEDA autoscaling, Helm-based multi-environment deployment, and full observability.

**Demo recording:** The live `/v1/completions` demonstration uses `Qwen/Qwen2.5-14B-Instruct` running on a real GPU dev cluster. The local setup below uses `facebook/opt-125m` so anyone can reproduce it without a GPU or cloud account.

**Terraform:** The IaC in `terraform/` is production-ready and `terraform plan`-verified. It is not applied to avoid cloud costs — the assessment criteria explicitly permits local equivalents. See [Local ↔ AWS Service Mapping](#local--aws-service-mapping).

## Repository Structure

```
.
├── terraform/
│   ├── modules/
│   │   ├── vpc/          # VPC, subnets, NAT, VPC endpoints
│   │   ├── eks/          # EKS cluster, GPU/system node groups, IRSA
│   │   └── ecr/          # ECR repository with lifecycle policy
│   └── environments/
│       └── prod/         # Root module wiring all modules together
├── helm/
│   ├── vllm-inference/          # vLLM inference chart
│   │   ├── Chart.yaml
│   │   ├── values.yaml          # base defaults (model, tolerations, probes)
│   │   └── templates/
│   │       ├── _helpers.tpl     # multi-cloud model download (aws/gcp/az)
│   │       └── qwen-deployment.yaml
│   ├── mlops-monitoring/        # Prometheus + Grafana + Loki + Alloy + Tempo
│   │   ├── Chart.yaml
│   │   └── values.yaml
│   ├── mlops-network/           # Istio + AWS Load Balancer Controller + External Secrets
│   │   ├── Chart.yaml
│   │   └── values.yaml
│   ├── mlops-gpu-operator/      # NVIDIA GPU Operator (device plugin, DCGM exporter, toolkit)
│   │   ├── Chart.yaml
│   │   └── values.yaml
│   ├── mlops-aibrix-system/     # AIBrix control plane + vLLM model deployments
│   │   ├── Chart.yaml           # depends on mlops-aibrix local subchart
│   │   └── charts/mlops-aibrix/
│   │       ├── Chart.yaml       # depends on aibrix upstream chart
│   │       ├── values.yaml      # base values (model config, storage, tolerations)
│   │       └── templates/
│   │           ├── _helpers.tpl          # multi-cloud download (aws/gcp/az)
│   │           ├── qwen_deployment.yaml  # Qwen vLLM deployment + initContainers
│   │           ├── qwen_service.yaml
│   │           ├── llama_deployment.yaml
│   │           ├── llama_service.yaml
│   │           └── virtual_services.yaml # Istio VirtualServices per model
│   └── values/                  # env-specific overrides (same pattern as apollo deploy/helm/values/)
│       ├── vllm-inference/{dev,staging,prod}/values.yaml
│       ├── mlops-monitoring/{dev,staging,prod}/values.yaml
│       ├── mlops-network/{dev,staging,prod}/values.yaml
│       ├── mlops-gpu-operator/{dev,staging,prod}/values.yaml
│       └── mlops-aibrix-system/{dev,staging,prod}/values.yaml
├── k8s/
│   ├── vllm/             # Raw manifests (reference / kubectl apply path)
│   ├── keda/             # KEDA ScaledObject
│   └── monitoring/       # Prometheus values, Grafana dashboard ConfigMap
├── docker/
│   ├── Dockerfile        # GPU production image (vllm/vllm-openai base)
│   └── Dockerfile.cpu    # CPU image for local dev & CI
├── .github/workflows/
│   ├── ci.yaml           # PR: lint + validate + CPU smoke test
│   └── deploy.yaml       # Main: build GPU image → ECR → helm upgrade
├── scripts/
│   ├── setup-local.sh    # One-command local stack (kind + full deploy)
│   ├── test-api.sh       # API smoke tests
│   └── port-forward.sh   # kubectl port-forwards helper
└── ARCHITECTURE.md
```

## Local Setup (no cloud required)

### Prerequisites

| Tool    | Version | Install |
|---------|---------|---------|
| Docker  | ≥ 24    | [docs.docker.com](https://docs.docker.com/get-docker/) |
| kind    | ≥ 0.22  | `brew install kind` |
| kubectl | ≥ 1.29  | `brew install kubectl` |
| helm    | ≥ 3.14  | `brew install helm` |

### One-command setup

```bash
chmod +x scripts/*.sh
./scripts/setup-local.sh
```

This will:
1. Start a local Docker registry on `localhost:5001`
2. Create a kind cluster with a simulated GPU worker node
3. Install NGINX ingress, KEDA, and kube-prometheus-stack
4. Build the CPU vLLM image and push to the local registry
5. Deploy vLLM with KEDA autoscaling
6. Pre-load the Grafana dashboard

Total time: **~10-15 minutes** (dominated by model download + image build).

### Access services

```bash
# Open port-forwards in a dedicated terminal
./scripts/port-forward.sh
```

| Service    | URL                                          |
|-----------|----------------------------------------------|
| vLLM API  | http://localhost:8000                        |
| Prometheus | http://localhost:9090                       |
| Grafana   | http://localhost:3000 (admin/changeme-in-production) |

### Test the API

```bash
# Automated smoke test (completions, chat, metrics)
./scripts/test-api.sh

# Manual curl
curl http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "facebook/opt-125m",
    "prompt": "The future of AI in regulated banking is",
    "max_tokens": 80,
    "temperature": 0.7
  }'
```

Expected response shape:
```json
{
  "id": "cmpl-...",
  "object": "text_completion",
  "choices": [{"text": "...", "finish_reason": "stop"}],
  "usage": {"prompt_tokens": 12, "completion_tokens": 80, "total_tokens": 92}
}
```

## Helm Deployment (Primary Production Path)

### Component install order

```
1. terraform apply              # VPC, EKS cluster, ECR, IAM/IRSA roles
2. mlops-gpu-operator           # NVIDIA device plugin + DCGM exporter (GPU nodes)
3. mlops-network                # Istio CRDs → istiod → ALB controller → external-secrets
4. mlops-monitoring             # Prometheus → Grafana → Loki → Alloy → Tempo
5. mlops-aibrix-system          # AIBrix CRDs → control plane → Qwen/Llama deployments
   (or vllm-inference)          # standalone vLLM path without AIBrix, for simpler deploys
```

The Helm chart handles environment separation, multi-model support, LoRA adapters, and multi-cloud model downloads. It mirrors the pattern used in production today.

```bash
# Deploy to dev
helm upgrade --install vllm-inference ./helm/vllm-inference \
  -f helm/vllm-inference/environments/dev/values.yaml \
  -n vllm --create-namespace

# Deploy to staging (pinned SHA)
helm upgrade --install vllm-inference ./helm/vllm-inference \
  -f helm/vllm-inference/environments/staging/values.yaml \
  --set vllm.image.tag=<candidate-sha> \
  -n vllm

# Deploy to prod (promoted staging SHA, requires 2-engineer approval in GitHub Environments)
helm upgrade --install vllm-inference ./helm/vllm-inference \
  -f helm/vllm-inference/environments/prod/values.yaml \
  --set vllm.image.tag=<promoted-sha> \
  -n vllm
```

Key parameters you'd fill in for your cluster (values.yaml placeholders):

| Placeholder | What to replace with |
|---|---|
| `ACCOUNT_ID` | AWS account ID |
| `REGION` | AWS region |
| `REPLACE_WITH_*_S3_UUID` | S3 path to model weights (content-addressed UUID) |
| `REPLACE_WITH_*_SHA` | Immutable image tag from ECR |

## AWS Production Setup

### Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform ≥ 1.7
- An S3 bucket + DynamoDB table for Terraform remote state

### 1. Configure variables

```bash
cp terraform/environments/prod/terraform.tfvars.example \
   terraform/environments/prod/terraform.tfvars
# Edit the file with your account-specific values
```

### 2. Provision infrastructure

```bash
cd terraform/environments/prod

terraform init \
  -backend-config="bucket=YOUR_STATE_BUCKET" \
  -backend-config="region=us-east-1"

terraform plan
terraform apply
```

Outputs you'll need:
```
cluster_name        = "mlops-eks"
ecr_repository_url  = "123456789012.dkr.ecr.us-east-1.amazonaws.com/vllm-inference"
vllm_irsa_role_arn  = "arn:aws:iam::123456789012:role/mlops-eks-vllm-role"
kubeconfig_command  = "aws eks update-kubeconfig --region us-east-1 --name mlops-eks"
```

### 3. Configure kubeconfig

```bash
$(terraform -chdir=terraform/environments/prod output -raw kubeconfig_command)
```

### 4. Deploy Kubernetes resources

```bash
# Update ACCOUNT_ID and REGION placeholders
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/vllm-inference:latest"

kubectl apply -f k8s/namespace.yaml

# Patch ServiceAccount with real IRSA ARN
IRSA_ARN=$(terraform -chdir=terraform/environments/prod output -raw vllm_irsa_role_arn)
sed "s|ACCOUNT_ID:role/mlops-eks-vllm-role|${IRSA_ARN#*:role/}|" \
  k8s/vllm/serviceaccount.yaml | kubectl apply -f -

# Patch Deployment with real image URL
sed "s|ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com|${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com|" \
  k8s/vllm/deployment.yaml | kubectl apply -f -

kubectl apply -f k8s/vllm/service.yaml
kubectl apply -f k8s/vllm/ingress.yaml
```

### 5. Enable GPU mode

In `k8s/vllm/deployment.yaml`, on the GPU node group:
1. Remove `--device cpu` and `--dtype float32` from `args`
2. Add `--dtype half --gpu-memory-utilization 0.90` to `args`
3. Uncomment `nvidia.com/gpu: "1"` in `resources.limits` and `resources.requests`
4. The NVIDIA device plugin DaemonSet ships with the `AL2_x86_64_GPU` AMI — no extra install needed

### 6. CI/CD (GitHub Actions)

Set the following in **GitHub → Settings → Variables** (repository level):

| Variable | Value |
|---|---|
| `AWS_REGION` | `us-east-1` |
| `AWS_DEPLOY_ROLE_ARN` | ARN of the GitHub OIDC IAM role |
| `ECR_REPOSITORY` | `vllm-inference` |
| `EKS_CLUSTER_NAME` | `mlops-eks` |

Create the GitHub OIDC IAM role:
```bash
# See: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html
# Trust policy subject: repo:YOUR_ORG/YOUR_REPO:ref:refs/heads/main
```

On every merge to `main`: CI builds the GPU Docker image, pushes to ECR with an immutable SHA tag, then triggers a rolling deployment to EKS with zero-downtime (`maxUnavailable: 0`).

## Local ↔ AWS Service Mapping

| Local (kind)            | AWS Production                          |
|-------------------------|-----------------------------------------|
| kind cluster            | EKS (managed control plane)            |
| Worker node (CPU)       | g4dn.xlarge node group (NVIDIA T4 GPU) |
| localhost:5001 registry | Amazon ECR (immutable tags, scan on push) |
| Kubernetes Secrets      | AWS Secrets Manager via IRSA           |
| NGINX ingress           | AWS Load Balancer Controller (ALB)     |
| emptyDir model volume   | EFS PVC or gp3 EBS PVC                 |
| Port-forward to 3000    | Internal ALB → Grafana                 |

## Secrets

No secrets are stored in this repository.

- **Local**: Grafana password is a placeholder (`changeme-in-production`). No real API keys needed for `facebook/opt-125m`.
- **Production**: HuggingFace token (for gated models) stored in AWS Secrets Manager at `mlops-eks/vllm/hf-token`. vLLM pod retrieves it via IRSA → Secrets Manager (no env vars, no mounted secrets).

## What I'd Do Next

See [ARCHITECTURE.md](ARCHITECTURE.md#whats-next) for the full prioritised list. Short version:

1. **Karpenter** — replace managed node groups with Karpenter for faster, cheaper GPU autoscaling (spot consolidation, bin-packing)
2. **Model registry** — MLflow or a versioned S3 prefix; decouple model from image so a model swap doesn't require a new container build
3. **Request routing** — route simple queries to a small model, complex ones to a large model, at the API gateway layer
4. **LoRA adapter hot-swapping** — serve multiple fine-tuned variants from one vLLM process
5. **PII redaction middleware** — intercept requests/responses before they hit the model for compliance
6. **SLO alerting** — p99 latency > 3s or error rate > 0.1% pages on-call
