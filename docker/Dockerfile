# Production image: GPU-capable, based on the official vLLM OpenAI-compatible server.
# For local CPU testing use Dockerfile.cpu instead.
#
# GPU production changes vs CPU local:
#   - Base image ships CUDA 12.1 + cuDNN + NVIDIA container toolkit
#   - Remove --device cpu and --dtype float32 from CMD
#   - Add --dtype half (FP16 for T4) or --dtype bfloat16 (for A10G/A100)
#   - Add --gpu-memory-utilization 0.90
#   - Uncomment nvidia.com/gpu: "1" in the Deployment resource limits
#   - Node group must use AL2_x86_64_GPU AMI + nvidia-device-plugin DaemonSet

FROM vllm/vllm-openai:v0.4.3

LABEL org.opencontainers.image.title="vllm-inference"
LABEL org.opencontainers.image.description="vLLM OpenAI-compatible inference server"
LABEL org.opencontainers.image.vendor="mlops-team"

# Prometheus client already bundled by vLLM; add any extra tooling here
RUN pip install --no-cache-dir \
    prometheus-client>=0.20.0 \
    opentelemetry-sdk>=1.20.0 \
    opentelemetry-exporter-otlp>=1.20.0

# Non-root user (vLLM base already creates 'vllm' uid=1000)
USER 1000

# Model weights directory — mount as PVC in production
RUN mkdir -p /home/vllm/.cache/huggingface

ENV HF_HOME=/home/vllm/.cache/huggingface \
    TRANSFORMERS_CACHE=/home/vllm/.cache/huggingface \
    # Prevent HuggingFace from phoning home for telemetry
    HF_HUB_DISABLE_TELEMETRY=1 \
    VLLM_WORKER_MULTIPROC_METHOD=spawn

HEALTHCHECK --interval=30s --timeout=15s --start-period=300s --retries=3 \
    CMD curl -sf http://localhost:8000/health || exit 1

EXPOSE 8000

# GPU production entrypoint — remove --device cpu for real GPU nodes
ENTRYPOINT ["python", "-m", "vllm.entrypoints.openai.api_server"]
CMD [ \
    "--model", "facebook/opt-125m", \
    "--port", "8000", \
    "--host", "0.0.0.0", \
    "--max-model-len", "2048", \
    "--dtype", "half", \
    "--gpu-memory-utilization", "0.90", \
    "--disable-log-requests" \
]
