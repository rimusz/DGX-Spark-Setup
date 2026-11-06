# shellcheck shell=bash
# Shared path helpers. Source only from scripts under scripts/<purpose>/.
# When a copy lives in ~/bin, this file is usually absent — callers fall back to SCRIPT_DIR.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"

pai_repo_root() {
  local d="${1:-${SCRIPT_DIR}}"
  while [ "$d" != "/" ]; do
    if [ -d "${d}/spark/bin" ] && {
         [ -f "${d}/AGENTS.md" ] || [ -f "${d}/README.md" ] || [ -f "${d}/scripts/spark-ops/setup-spark.sh" ]
       }; then
      printf '%s\n' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}

REPO_ROOT="$(pai_repo_root "${SCRIPT_DIR}" || true)"

# Print path to a script by basename (repo tree, then ~/bin).
pai_script() {
  local name="$1"
  local src=""
  if [ -f "${SCRIPT_DIR}/${name}" ]; then
    printf '%s\n' "${SCRIPT_DIR}/${name}"
    return 0
  fi
  if [ -n "${REPO_ROOT:-}" ]; then
    src="$(find "${REPO_ROOT}/scripts" -maxdepth 2 -type f -name "${name}" 2>/dev/null | head -1)"
    if [ -n "${src}" ]; then
      printf '%s\n' "${src}"
      return 0
    fi
  fi
  if [ -f "${HOME}/bin/${name}" ]; then
    printf '%s\n' "${HOME}/bin/${name}"
    return 0
  fi
  return 1
}
