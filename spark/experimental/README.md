# Experimental / native-build scripts

These were used while diagnosing GB10 native vLLM. **Production serving uses Docker** (`../bin/vllm-qwen35-docker.sh`).

| Script | Purpose |
|--------|---------|
| `install-vllm-native.sh` | eelbaz one-liner install |
| `resume-vllm-install.sh` | Resume after `apache-tvm-ffi` pin failure |
| `build-vllm.sh` | Rebuild editable install |
| `fix-and-rebuild-vllm.sh` | CMake MoE arch patch + rebuild |
| `upgrade-vllm-qwen35.sh` | Attempt main branch for Qwen3.5 (often fails on torch stable ABI) |

Do not enable `vllm-qwen35.service` until a native binary can load `Qwen3_5MoeForConditionalGeneration`.
