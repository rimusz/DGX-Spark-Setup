#!/usr/bin/env bash
# Compat: last-model reboot is spark-boot.sh (deepseek|deepseek-ds4).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spark-boot.sh" "$@"
