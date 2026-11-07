# Model launchers

| Key | Directory / script | Upstream | Engine | Port |
|-----|--------------------|----------|--------|------|
| `qwen` | `../bin/vllm-qwen35-docker.sh` | this repo | **vLLM Docker** (data analysis: **6 seqs / 131k**) | **8000** |
| `deepseek` | `deepseek/` | [rimusz/DeepSeek-v4-Flash-One-DGX-Spark](https://github.com/rimusz/DeepSeek-v4-Flash-One-DGX-Spark) | **EXL3 / SparkInfer** (`start-exl3.sh`); GGUF backup `start.sh` (`sm start deepseek-ds4`) | **8001** |

Prefer `sm` / `spark-model` for start/stop/pull. Only one model should run at a time.
