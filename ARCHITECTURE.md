# Architecture & Trade-offs: LLM Inference Platform for a Regulated Bank

## Executive Summary

This document covers the design of a production-grade LLM inference platform appropriate for a regulated bank's conversational AI workloads. The bank is on a two-phase arc: **today**, it routes inference through a managed provider (Bedrock or an OpenAI-compatible API) to move fast; **tomorrow**, it moves to self-hosted model serving on GPU-accelerated EKS nodes to regain control over data residency, cost, and model lifecycle.

The build challenge in this repository represents the target state: a vLLM service on EKS, with KEDA autoscaling, a full observability stack, and a zero-downtime CI/CD pipeline. This document explains why each choice was made, what was traded away, and what comes next.

---

## 1. Current State: Managed Inference

```
Client → API Gateway → Lambda/Service → Bedrock / OpenAI-compatible API → Model
```

### Advantages
- Zero operational overhead — no GPUs, no drivers, no model serving infrastructure
- Rapid iteration — swap models by changing a config string
- No cold-start; provider handles capacity

### Problems at scale for a regulated bank

| Problem | Detail |
|---|---|
| **Data residency** | Prompts leave the VPC. PII, transaction data, and customer communication hit a third-party API — a direct conflict with data sovereignty obligations under GDPR, MAS TRM, and similar frameworks. |
| **Cost curve** | Per-token pricing is efficient at low volume. At 10M+ tokens/day the bill exceeds the cost of dedicated GPU hardware within months. |
| **Model governance** | The bank cannot pin to a specific model version. Provider-side updates can silently change output behaviour, which is unacceptable when model outputs drive decisions in a supervised-learning pipeline or a customer-facing chatbot under consumer protection rules. |
| **Audit trail** | Inference requests and responses must be logged, attributable, and immutable for regulatory examination. Managed providers offer limited audit capability compared to a system the bank controls end-to-end. |

---

## 2. Target State: Self-Hosted vLLM on EKS GPU

```
Client
  └─▶ Internal ALB (TLS 1.3, WAF)
        └─▶ vLLM Pods (EKS, GPU nodes)
              ├─▶ NVIDIA T4 / A10G GPU
              ├─▶ Prometheus /metrics
              └─▶ Model weights (EFS or S3-backed PVC)
```

### Why vLLM

vLLM is the de-facto production inference engine for transformer models:

- **PagedAttention** — manages GPU KV cache with a paging scheme borrowed from OS virtual memory. Eliminates fragmentation; enables high-concurrency batching that utilises >90% of VRAM vs ~50% with naive implementations.
- **Continuous batching** — processes new requests without waiting for the current batch to finish. Dramatically improves throughput vs static batching.
- **OpenAI-compatible API** — `/v1/completions` and `/v1/chat/completions` are drop-in replacements. Zero client-side code changes when migrating from Bedrock.
- **Tensor parallelism** — splits a model across multiple GPUs within one node. Required for models larger than a single GPU's VRAM (e.g., 70B+ parameter models).

### Model choice

| Scenario | Model | Why |
|---|---|---|
| Assessment / local demo | `facebook/opt-125m` | Runs on CPU in minutes; proves the plumbing |
| Near-term production | `Qwen/Qwen2.5-14B-Instruct` | Strong multilingual instruction-following, 14B fits on a single T4 (with 8-bit quant) or comfortably on A10G in FP16; strong finance/regulatory domain performance |
| High-capability | `Qwen/Qwen2.5-72B-Instruct` | Requires tensor parallelism across 4 GPUs; fits on a single g6e.12xlarge (4× L40S, 192 GB VRAM) with FP8 quantisation, or g6e.48xlarge in FP16 — competitive with GPT-4 on many benchmarks |

The `Qwen2.5-14B-Instruct` model is used in the live demo recording. The Kubernetes manifests default to `facebook/opt-125m` for cost-free local reproducibility, with inline comments documenting every flag that changes in production.

---

## 3. Infrastructure Design

### 3.1 EKS Cluster

```
EKS Control Plane (AWS Managed)
  │
  ├─ system node group    (t3.medium × 2–4, ON_DEMAND)   [taint: CriticalAddonsOnly]
  │    └─ coredns, kube-proxy, vpc-cni, ebs-csi, pod-identity-agent
  │
  ├─ general node group   (m7i.4xlarge × 2–8, ON_DEMAND)  [no taint]
  │    └─ monitoring (Prometheus, Grafana, Loki, Tempo),
  │       KEDA, AIBrix control plane, External Secrets,
  │       application services, ingress controller
  │
  └─ gpu node group       (g6e.12xlarge × 1–4, ON_DEMAND)  [taint: nvidia.com/gpu=present]
       └─ vLLM / AIBrix model pods only
```

**Why three separate node groups?**
- **System** (tainted `CriticalAddonsOnly`): keeps K8s core add-ons isolated from eviction pressure; t3.medium is cost-minimal.
- **General** (untainted): all platform services schedule here by default; m7i.4xlarge provides 16 vCPU / 64 GB per node — enough to run the full monitoring stack (Prometheus ~4 GB, Loki distributed ~8 GB, Grafana ~2 GB) alongside AIBrix and KEDA without CPU contention.
- **GPU** (tainted `nvidia.com/gpu=present:NoSchedule`): exclusive to model pods. g6e.12xlarge ($16.29/hr on-demand) carries 4× NVIDIA L40S GPUs (192 GB VRAM total). Running any non-GPU workload on it wastes ~$15/hr and evicts model pods when memory pressure builds.

**Node group sizing rationale:**

| Instance | GPU | VRAM | Fits |
|---|---|---|---|
| g4dn.xlarge | NVIDIA T4 | 16 GB | Qwen2.5-14B at INT8 quant (~10 GB) — dev only |
| g5.2xlarge | A10G | 24 GB | Qwen2.5-14B FP16 comfortably; 20% headroom |
| g6e.xlarge | 1× L40S | 48 GB | Qwen2.5-14B FP16 with generous headroom |
| **g6e.12xlarge** | **4× L40S** | **192 GB** | **★ this stack — 14B TP=2, 72B FP8 TP=4** |

**Production recommendation:** Use `g6e.12xlarge` (this stack) — 4× L40S gives enough VRAM for 14B in FP16 with TP=2 (leaves headroom for other models) or 72B in FP8 with TP=4. The larger VRAM pool also reduces KV-cache eviction under bursty traffic, which matters for financial chatbot latency SLOs.

### 3.2 Networking

All nodes in **private subnets**. No public IPs on GPU nodes. Traffic flows:

```
Internet → CloudFront (optional) → External ALB (public subnet)
                                         ↓
                               Internal ALB (private subnet)
                                         ↓
                                 vLLM Service (ClusterIP)
                                         ↓
                                    vLLM Pod
```

For internal bank applications (the primary use case), the external ALB is omitted entirely. Requests come from inside the VPC over Direct Connect or a Transit Gateway.

**VPC Endpoints** keep ECR, S3, and Secrets Manager traffic on the AWS backbone — no internet egress for the data plane. This satisfies "no data leaves the network perimeter" compliance requirements.

### 3.3 Secrets Management

| Secret | Storage | Access pattern |
|---|---|---|
| HuggingFace token | AWS Secrets Manager | Pod reads via IRSA at startup |
| Grafana admin password | Secrets Manager | External Secrets Operator syncs to K8s Secret |
| Model API keys (outbound calls) | Secrets Manager | Application code; never env vars |
| TLS certificates | ACM | ALB terminates; pods never see private keys |

**IRSA (IAM Roles for Service Accounts):** the vLLM pod's ServiceAccount has an annotation pointing to an IAM role. The EKS OIDC provider issues a JWT; the pod exchanges it for temporary AWS credentials scoped to exactly `secretsmanager:GetSecretValue` on paths matching `mlops-eks/vllm/*`. No long-lived credentials anywhere.

---

## 4. Autoscaling Strategy

### 4.1 Why KEDA, not plain HPA

The standard HPA scales on CPU/memory. Neither proxy reliably for GPU inference demand:

- A model can sit at **20% GPU utilisation** while 50 requests queue up (they're waiting for the current batch to finish, not for compute capacity).
- Memory is **pinned at model-load time** regardless of request volume — the HPA would never trigger.

KEDA scales on **Prometheus metrics**, specifically `vllm:num_requests_waiting` — the actual queue depth. This directly measures backpressure.

```
ScaledObject trigger:
  query: sum(vllm:num_requests_waiting) / current_replicas > 5
  → add a replica for every 5 queued requests
```

A secondary trigger on `vllm:gpu_cache_usage_perc > 80%` catches the case where the KV cache is saturated before the queue builds up (high-context workloads).

### 4.2 Scale-to-zero vs minReplicas: 1

Inference pods take **2-5 minutes** to start (pull image, load model weights into VRAM, warm up). Scale-to-zero would impose an unacceptable cold-start for a user-facing chatbot. `minReplicaCount: 1` keeps one warm pod always available.

In a batch processing scenario (nightly document analysis, not user-facing), scale-to-zero on a longer cooldown period is appropriate.

### 4.3 Node autoscaling

KEDA handles pod autoscaling. For **node** autoscaling, Karpenter (see §8) is the right answer — it's aware of GPU taints and can provision a g4dn.xlarge in ~90 seconds vs ~5 minutes for managed node group ASG warm-up.

In this repository, the GPU node group uses `min_size = 0 / desired_size = 1` with a Terraform `lifecycle { ignore_changes = [desired_size] }` so the Cluster Autoscaler (or Karpenter) can manage scale-down without Terraform fighting it.

### 4.4 Cooldown tuning

300-second scale-down cooldown is intentionally conservative. GPU nodes are expensive to start and models are expensive to load. Premature scale-down followed by a traffic spike means users wait minutes for a warm pod. At $0.53/hr a g4dn.xlarge costs ~$0.009 per idle 60 seconds — a cheap insurance policy against latency spikes.

---

## 5. Environment Strategy & Promotion Flow

### 5.1 Folder-based environment separation (Helm)

The inference stack is packaged as a single Helm chart (`helm/vllm-inference/`) with a base `values.yaml` and environment-specific override files:

```
helm/vllm-inference/
├── Chart.yaml
├── values.yaml                    # base defaults (model, tolerations, probes)
├── templates/
│   ├── _helpers.tpl               # multi-cloud model download helpers (aws/gcp/az)
│   ├── qwen-deployment.yaml       # Qwen model Deployment (conditional on qwen.enabled)
│   ├── llama-deployment.yaml      # Llama model Deployment (conditional on llama.enabled)
│   ├── service.yaml
│   ├── ingress.yaml
│   └── keda-scaledobject.yaml
└── environments/
    ├── dev/values.yaml            # smaller resources, :latest tag, no LoRA, 2 replicas max
    ├── staging/values.yaml        # prod-mirror config, pinned SHA, LoRA enabled
    └── prod/values.yaml           # full resources, immutable SHA, minReplicas: 2, ALB ingress
```

**Key parameterisation points:**

| Parameter | Dev | Staging | Prod |
|---|---|---|---|
| `vllm.image.tag` | `:latest` | `:<sha>` (candidate) | `:<sha>` (promoted) |
| `qwen.tensorParallelSize` | 1 | 1 | 1–4 (model-dependent) |
| `qwen.maxModelLen` | 8192 | 32768 | 131072 |
| `qwen.autoscaling.minReplicas` | 1 | 1 | 2 |
| `qwen.lora.enabled` | false | true | true |
| `model_storage.model_storage_location` | `dev-mlops-model-weights` | `staging-mlops-model-weights` | `prod-mlops-model-weights` |
| `ingress.className` | nginx | nginx | alb |
| `global.serviceAccountName` | `dev-vllm` | `staging-vllm` | `prod-vllm` |

### 5.2 Promotion flow

```
Developer branch
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│  PR opened                                                       │
│  ci.yaml: terraform lint → kubeval → helm lint → CPU smoke test │
└───────────────────────────────┬─────────────────────────────────┘
                                │ merge
                                ▼
┌────────────────────────────────────────┐
│  Dev environment (EKS dev cluster)     │
│  deploy.yaml: build GPU image → ECR   │
│  helm upgrade -f environments/dev/     │
│  Run integration test suite            │
│  Tag image: <sha>-dev-verified         │
└──────────────────┬─────────────────────┘
                   │ pass + manual promote button in GitHub
                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│  Staging environment (EKS staging cluster, prod-mirror)                │
│  helm upgrade -f environments/staging/                                  │
│  image.tag = promoted SHA                                               │
│  Run full eval suite: latency SLO check, accuracy regression, load test│
│  Tag image: <sha>-staging-verified                                      │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ pass + 2-engineer approval in GitHub Environments
                                    ▼
┌────────────────────────────────────────────────┐
│  Production environment (EKS prod cluster)     │
│  helm upgrade -f environments/prod/             │
│  image.tag = staging-verified SHA              │
│  Rolling update (maxUnavailable: 0)            │
│  Smoke test against prod ALB                   │
│  On failure: helm rollback vllm-inference 0    │
└────────────────────────────────────────────────┘
```

### 5.3 Model weight promotion (separate from image promotion)

Model weights are **decoupled from the container image**. The image contains the vLLM runtime; the model is fetched at pod startup via an init container from S3. This means:

- A model update (new fine-tune, new quantised checkpoint) does **not** require a new container build or CI pipeline run
- The model is referenced by a **content-addressed S3 UUID** in the values file — updating the UUID is the promotion mechanism
- To promote a model: open a PR updating `model_storage.qwen.model_path` in the target environment's `values.yaml`, get approval, merge

This separation is the same pattern used in the apollo/aibrix stack. It eliminates the coupling between the LLM runtime release cycle and the model research cycle.

### 5.4 LoRA adapter lifecycle

LoRA adapters follow the same env-separation pattern:

```
Research trains adapter → uploads to staging S3 bucket
→ PR updates model_storage.qwen.lora_adapter_path in staging/values.yaml
→ Eval confirms quality regression < threshold
→ PR promotes UUID to prod/values.yaml
→ Helm upgrade → init container downloads new adapter → vLLM hot-loads it
```

vLLM's `--enable-lora` allows multiple adapters to be loaded without restarting the server, so adapter promotion has near-zero downtime.

---

## 7. CI/CD Pipeline

```
PR opened
  └─ ci.yaml
       ├─ terraform fmt + validate
       ├─ kubeval (manifest schema check)
       └─ docker build Dockerfile.cpu → smoke test (completions + metrics)

Merge to main
  └─ deploy.yaml
       ├─ OIDC → assume IAM role (no long-lived keys in CI)
       ├─ docker build Dockerfile (GPU) → push to ECR :SHA + :latest
       ├─ kubectl set image → rollout (maxUnavailable: 0)
       ├─ kubectl rollout status (timeout 10m)
       └─ smoke test against live ALB endpoint
            └─ on failure: kubectl rollout undo
```

**Key design decisions:**

- **OIDC, not access keys.** GitHub Actions supports OIDC federation with AWS IAM. The CI role is scoped to `ecr:PutImage` on the specific repository and `eks:DescribeCluster` + `sts:AssumeRole` for kubeconfig. Rotating credentials is not a toil item because there are none.
- **Immutable tags.** ECR is configured with `imageTagMutability = IMMUTABLE`. `:latest` can be pushed but never overwrites a SHA tag. Rollback is `kubectl set image` with a prior SHA — always available.
- **`maxUnavailable: 0`.** The rolling update strategy never terminates a running pod before the replacement passes readiness checks. This prevents the brief window of capacity loss that would happen with the default 25% unavailable.
- **GPU image in CI.** The GPU image is built in CI using `docker/Dockerfile` (which inherits from `vllm/vllm-openai`) and pushed to ECR. Functional testing in CI uses `Dockerfile.cpu` against the same entrypoint — validates routing, parsing, and metric emission without requiring a GPU runner.
- **GitHub Environments + approval gates.** The `deploy` job is scoped to the `production` environment, which can require a human reviewer to approve before `kubectl set image` runs. This gives the bank's change management process a hook without requiring a separate pipeline tool.

---

## 8. Observability

### 6.1 Metrics (Prometheus + Grafana)

vLLM exposes a `/metrics` endpoint with the following key signals:

| Metric | Type | Meaning |
|---|---|---|
| `vllm:e2e_request_latency_seconds` | Histogram | End-to-end wall-clock latency per request |
| `vllm:num_requests_running` | Gauge | Requests actively being processed |
| `vllm:num_requests_waiting` | Gauge | Requests queued (KEDA trigger input) |
| `vllm:gpu_cache_usage_perc` | Gauge | KV cache utilisation (VRAM pressure) |
| `vllm:generation_tokens_total` | Counter | Tokens generated (throughput KPI) |
| `vllm:prompt_tokens_total` | Counter | Prompt tokens processed (input cost KPI) |
| `vllm:num_preemptions_total` | Counter | Requests evicted from cache (signals memory pressure) |

The Grafana dashboard (pre-loaded via ConfigMap) shows these across a single pane with threshold-coloured gauges for KV-cache and request-queue.

**Proposed SLOs:**

| Objective | Target |
|---|---|
| p95 request latency (14B model, 512 output tokens) | < 8 seconds |
| p99 request latency | < 15 seconds |
| Error rate (5xx) | < 0.1% |
| Availability | 99.9% (three nines) |

### 6.2 Logs (Loki / CloudWatch)

In a production deployment, log aggregation would plug into an existing platform stack:
- Fluent Bit DaemonSet ships pod logs to **Loki** (self-hosted, if already deployed) or **CloudWatch Logs** (zero-infra, but costly at high volume)
- vLLM request logs (disabled by `--disable-log-requests` in the CMD for performance) can be re-enabled and shipped to an audit log store. For a regulated bank, a separate append-only audit log group with 7-year retention and SCPs preventing deletion is standard.

### 6.3 Traces (OpenTelemetry)

For multi-hop requests (client → API gateway → vLLM → downstream tools), distributed tracing via OpenTelemetry with Tempo or AWS X-Ray gives span-level visibility into where latency lives. The `vllm-inference` image includes the OpenTelemetry SDK; enabling it requires passing `--otlp-traces-endpoint` at startup.

### 6.4 DCGM Exporter (GPU hardware metrics)

For GPU nodes, the NVIDIA Data Center GPU Manager (DCGM) Exporter DaemonSet exposes:
- `DCGM_FI_DEV_GPU_UTIL` — GPU compute utilisation %
- `DCGM_FI_DEV_MEM_COPY_UTIL` — memory bandwidth utilisation
- `DCGM_FI_DEV_FB_USED` / `DCGM_FI_DEV_FB_FREE` — VRAM used/free (absolute, not %)
- `DCGM_FI_DEV_POWER_USAGE` — watt draw per GPU

These complement vLLM's application-level metrics and are essential for infrastructure-level capacity planning. The DCGM exporter is deployed as a DaemonSet targeting nodes with the `nvidia.com/gpu=present` label.

---

## 9. Security & Compliance (Regulated Bank)

### 7.1 Data plane isolation

- All inference nodes are in **private subnets** with no internet route
- VPC endpoints for ECR, S3, Secrets Manager — data never traverses the internet
- Security group rules: GPU nodes accept traffic only from the Kubernetes control plane and the ALB security group; all other ingress denied
- No SSH — node access via AWS Systems Manager Session Manager only (audit log in CloudTrail)

### 7.2 Encryption

| Layer | Mechanism |
|---|---|
| Data in transit | TLS 1.3 (ALB to client); mTLS between pods via Istio (optional) |
| Data at rest (EBS/EFS) | AES-256 via KMS customer-managed key |
| EKS secrets (etcd) | KMS CMK envelope encryption (configured in Terraform) |
| ECR images | AES-256 |
| CloudWatch Logs | KMS CMK |

### 7.3 Model governance

In a regulated environment, a model cannot be swapped without a change management record:

1. **Approved model registry** — a versioned S3 prefix (or MLflow model registry) listing approved model IDs and SHA digests. The CI/CD pipeline verifies the model before deploying.
2. **Immutable deployment artifacts** — the model weights hash and the container image SHA are both recorded in the deployment annotation (`kubectl.kubernetes.io/last-applied-configuration`) and in the Git-tagged release.
3. **Model impact assessment** — a lightweight eval suite (accuracy on a held-out test set, toxicity screening) runs in CI against the new model before the green light to deploy.

### 7.4 Audit logging

For compliance (e.g., MAS TRM Guideline on AI), every inference call must be traceable to a user identity and a point in time:

- Request/response logging: vLLM supports structured request logging; ship to an append-only CloudWatch Logs group with a resource policy denying `logs:DeleteLogGroup`
- User attribution: upstream API gateway (Kong, or an ALB listener rule) injects a `X-User-ID` header; vLLM logs include it
- Retention: 7 years, SCPs preventing deletion on the audit log account

### 7.5 PII handling

Before prompts reach vLLM and after responses are generated, a middleware layer should:
1. Detect PII (NLP-based entity recogniser or a rule engine like AWS Comprehend)
2. Redact or pseudonymise before the prompt is logged
3. Optionally block the request if it contains raw account numbers, NRICs, etc.

This middleware is not in scope for this assessment but is a mandatory first feature in production.

---

## 10. Managed vs Self-Hosted: Trade-off Summary

| Dimension | Managed (Bedrock/OpenAI) | Self-Hosted (vLLM on EKS) |
|---|---|---|
| **Data residency** | ❌ Prompts leave VPC | ✅ Never leaves network |
| **Regulatory compliance** | ❌ Hard to satisfy | ✅ Designed for it |
| **Operational complexity** | ✅ Near zero | ❌ High (GPU infra, drivers, serving) |
| **Cost at scale** | ❌ Expensive | ✅ 5-10× cheaper at 10M+ tokens/day |
| **Model control** | ❌ Provider upgrades silently | ✅ Pin exact version |
| **Latency** | ~500ms–2s (network + queue) | ~200ms–1s (on-premise T4) |
| **Cold start** | ✅ None | ❌ 2-5 min per pod |
| **Time to first token** | Varies | Predictable (streaming reduces perceived latency) |
| **Model selection** | Provider's catalogue | Any open-weight model |

**Decision framework:** use managed inference until the bank's inference volume crosses ~5M tokens/day OR until a data residency requirement blocks the managed provider. The migration can be phased (shadow mode, traffic split) with zero flag day.

---

## 11. GPU Instance Trade-offs

| Instance | GPU | VRAM | vCPU | RAM | On-Demand $/hr | Best for |
|---|---|---|---|---|---|---|
| g4dn.xlarge | 1× T4 | 16 GB | 4 | 16 GB | $0.53 | Dev / cost-sensitive; 7B INT8 |
| g5.2xlarge | 1× A10G | 24 GB | 8 | 32 GB | $1.21 | 14B FP16 comfortably |
| g6.12xlarge | 4× L4 | 96 GB | 48 | 192 GB | $7.83 | 14B TP=4 or 70B INT8 |
| **g6e.12xlarge** | **4× L40S** | **192 GB** | **48** | **192 GB** | **$16.29** | **★ this stack — 14B TP=2, 72B FP8 TP=4** |
| g6e.48xlarge | 8× L40S | 384 GB | 192 | 768 GB | $65.07 | 405B+ or high-TP multi-model |
| p4d.24xlarge | 8× A100 | 320 GB | 96 | 1152 GB | $32.77 | Training; frontier inference |
| p5.48xlarge | 8× H100 | 640 GB | 192 | 2048 GB | $98.32 | State-of-the-art training/inference |

**Spot vs On-Demand for inference:** Spot instances are 60–70% cheaper but can be interrupted with 2-minute notice. Viable for batch inference jobs; not acceptable for synchronous user-facing chatbot traffic unless the application layer handles interruptions gracefully (retry with backoff to another AZ's On-Demand pod). A mixed strategy — 1 On-Demand base pod + KEDA bursting to Spot — is a good middle ground.

---

## 12. What's Next

Ordered by highest impact:

### P0 — Required before production traffic

1. **PII redaction middleware** — intercept all prompts/responses; no raw PII in logs
2. **Karpenter** — replace managed node groups; sub-2-minute node provisioning, bin-packing, automatic Spot consolidation
3. **mTLS (Istio)** — encrypt pod-to-pod traffic for defence-in-depth
4. **Model eval CI gate** — eval suite in pipeline; block deploy on regression

### P1 — Operational maturity

5. **Model weights on EFS PVC** — decouple model from pod lifecycle; pods start in seconds rather than downloading weights at init
6. **SLO alerting** — Prometheus alerting rules → PagerDuty for p99 > SLO and error_rate > threshold
7. **Thanos / Cortex** — long-term metric storage; Prometheus retention limited to 15 days
8. **Request routing layer** — route by prompt complexity (token count, task type) to a small model first; escalate to large model on failure or low confidence

### P2 — Cost and capability

9. **LoRA adapter hot-swap** — serve multiple fine-tuned variants (customer-service, compliance Q&A, code assistant) from one vLLM process without separate GPU allocations
10. **Quantisation evaluation** — benchmark AWQ (Activation-aware Weight Quantisation) vs GPTQ vs FP16 on the bank's task distribution; often 2× throughput gain with <1% accuracy loss
11. **Multi-region** — active-passive failover for DR; model weights replicated to secondary region via S3 cross-region replication
12. **Batch inference pipeline** — separate vLLM deployment with scale-to-zero for nightly document classification/summarisation jobs; cost-isolated from real-time traffic
