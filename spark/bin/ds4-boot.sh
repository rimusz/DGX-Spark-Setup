#!/usr/bin/env bash
# Compat: last-model reboot is spark-boot.sh (qwen|deepseek|ling).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spark-boot.sh" "$@"
