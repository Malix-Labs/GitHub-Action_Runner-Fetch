#!/usr/bin/env bash
set -euo pipefail

if ! command -v ncdu >/dev/null 2>&1; then
  sudo apt-get install -y -qq --no-install-recommends ncdu >/dev/null 2>&1 || true
fi

OUT_DIR="${RUNNER_TEMP:-/tmp}/runner-fetch"
mkdir -p "$OUT_DIR"

ENV_JSON=$(jq -c -n \
  --arg os "${RUNNER_OS:-Linux}" \
  --arg arch "${RUNNER_ARCH:-$(uname -m)}" \
  --arg name "${RUNNER_NAME:-unknown}" \
  --arg hostname "$(hostname)" \
  --arg kernel "$(uname -r)" \
  --arg uptime "$(awk '{print $1}' /proc/uptime 2>/dev/null || echo '0')" \
  '{
    runner_os: $os,
    runner_arch: $arch,
    runner_name: $name,
    hostname: $hostname,
    kernel: $kernel,
    uptime_seconds: $uptime
  }')

STORAGE_JSON=$(lsblk --json -o NAME,FSTYPE,LABEL,UUID,FSAVAIL,FSUSE%,SIZE,MOUNTPOINT,TYPE 2>/dev/null | jq -c '.' || echo '{"blockdevices":[]}')
CPU_JSON=$(lscpu --json 2>/dev/null | jq -c '.' || echo '{"lscpu":[]}')
HARDWARE_JSON=$(sudo lshw -json -sanitize 2>/dev/null | jq -c '.' || echo '{}')

sudo ncdu -o "${OUT_DIR}/disk_tree.json" -q / 2>/dev/null || echo '[]' >"${OUT_DIR}/disk_tree.json"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  emit_gha_output() {
    local name="$1"
    local data="$2"
    {
      echo "${name}<<EOF_${name}"
      echo "${data}"
      echo "EOF_${name}"
    } >>"${GITHUB_OUTPUT}"
  }

  emit_gha_output "environment" "${ENV_JSON}"
  emit_gha_output "cpu" "${CPU_JSON}"
  emit_gha_output "storage" "${STORAGE_JSON}"
  emit_gha_output "hardware" "${HARDWARE_JSON}"
  emit_gha_output "disk_tree_path" "${OUT_DIR}/disk_tree.json"
fi
