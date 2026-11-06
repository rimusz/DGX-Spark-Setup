# Third-party Spark model launchers

Upstream scripts vendored (lightly port-defaulted) from MiaAI-Lab. Prefer `~/bin/spark-model` for exclusive start/stop.

| Directory | Upstream | Engine | Default port (via spark-model) |
|-----------|----------|--------|--------------------------------|
| `deepseek/` | [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark) (8/256k/:8001) | **EXL3 / SparkInfer** (`start-exl3.sh`); GGUF backup `start.sh` (`sm start deepseek-ds4`) | **8001** |
| `ling/` | [Ling-3.0-Flash-SGLang-DGX-Spark](https://github.com/MiaAI-Lab/Ling-3.0-Flash-SGLang-DGX-Spark) | **SGLang** Docker | **8002** |

Qwen stays in `spark/bin/vllm-qwen35-docker.sh` (vLLM Docker, port **8000**).

Weight prefetch uses the host Hugging Face `hf` CLI (`setup-spark.sh` → `ensure-hf-cli.sh` → `~/.local/bin`). Ling’s `start.sh --download-only` calls the same CLI when present.

**Only one heavy model should run at a time** on a single GB10 (~128 GB unified).
