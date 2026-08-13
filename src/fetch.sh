#!/usr/bin/env bash
set -euo pipefail

if ! command -v ncdu >/dev/null 2>&1; then
  sudo apt-get install -y -qq --no-install-recommends ncdu >/dev/null 2>&1 || true
fi

ENV_JSON=$(jq -n \
  --arg os "${RUNNER_OS:-Linux}" \
  --arg arch "${RUNNER_ARCH:-$(uname -m)}" \
  --arg name "${RUNNER_NAME:-unknown}" \
  --arg hostname "$(hostname)" \
  --arg kernel "$(uname -r)" \
  --arg distro "$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || uname -s)" \
  --arg uptime "$(awk '{print $1}' /proc/uptime 2>/dev/null || echo 0)" \
  '{runner_os: $os, runner_arch: $arch, runner_name: $name, hostname: $hostname, kernel: $kernel, distro: $distro, uptime_seconds: $uptime}')

STORAGE_JSON=$(lsblk --json -o NAME,FSTYPE,LABEL,UUID,FSAVAIL,FSUSE%,SIZE,MOUNTPOINT,TYPE 2>/dev/null || echo '{"blockdevices":[]}')
CPU_JSON=$(lscpu --json 2>/dev/null || echo '{"lscpu":[]}')
HARDWARE_JSON=$(command -v lshw >/dev/null 2>&1 && sudo lshw -json -sanitize 2>/dev/null || echo '{}')
DISK_TREE_JSON=$(command -v ncdu >/dev/null 2>&1 && sudo ncdu -o - -q / 2>/dev/null || echo '[]')

echo "=== ENVIRONMENT ===" && echo "$ENV_JSON"
echo "=== CPU ===" && echo "$CPU_JSON"
echo "=== STORAGE ===" && echo "$STORAGE_JSON"
echo "=== HARDWARE ===" && echo "$HARDWARE_JSON"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  emit_output() {
    local key="$1"
    local val="$2"
    echo "${key}<<EOF" >> "$GITHUB_OUTPUT"
    echo "$val" | jq -c '.' >> "$GITHUB_OUTPUT"
    echo "EOF" >> "$GITHUB_OUTPUT"
  }
  emit_output "environment" "$ENV_JSON"
  emit_output "cpu" "$CPU_JSON"
  emit_output "storage" "$STORAGE_JSON"
  emit_output "hardware" "$HARDWARE_JSON"
  emit_output "disk_tree" "$DISK_TREE_JSON"
fi

