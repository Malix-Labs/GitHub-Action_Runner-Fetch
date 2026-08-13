#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${RUNNER_TEMP:-/tmp}/runner-fetch"
mkdir -p "$OUT_DIR"
DISK_TREE_FILE="${OUT_DIR}/disk_tree.json"

TARGET_OS="${RUNNER_OS:-Linux}"

if ! command -v dust >/dev/null 2>&1; then
  if [ "$TARGET_OS" = "Linux" ]; then
    curl -sL https://github.com/bootandy/dust/releases/download/v1.1.1/dust-v1.1.1-x86_64-unknown-linux-musl.tar.gz | tar -xz -C "$OUT_DIR" 2>/dev/null || true
  elif [ "$TARGET_OS" = "macOS" ]; then
    curl -sL https://github.com/bootandy/dust/releases/download/v1.1.1/dust-v1.1.1-x86_64-apple-darwin.tar.gz | tar -xz -C "$OUT_DIR" 2>/dev/null || true
  fi
fi

DUST_BIN="dust"
if [ -f "${OUT_DIR}/dust" ]; then
  DUST_BIN="${OUT_DIR}/dust"
fi

case "$TARGET_OS" in
  "Linux")
    ENV_JSON=$(jq -c -n \
      --arg os "Linux" \
      --arg arch "${RUNNER_ARCH:-$(uname -m)}" \
      --arg name "${RUNNER_NAME:-unknown}" \
      --arg hostname "$(hostname)" \
      --arg kernel "$(uname -r)" \
      --arg uptime "$(awk '{print $1}' /proc/uptime 2>/dev/null || echo '0')" \
      '{runner_os: $os, runner_arch: $arch, runner_name: $name, hostname: $hostname, kernel: $kernel, uptime_seconds: $uptime}')

    STORAGE_JSON=$(lsblk -b -O --json 2>/dev/null | jq -c '.' || echo '{"blockdevices":[]}')
    CPU_JSON=$(lscpu --json 2>/dev/null | jq -c '.' || echo '{"lscpu":[]}')
    HARDWARE_JSON=$(sudo lshw -json -sanitize 2>/dev/null | jq -c '.' || echo '{}')

    if command -v "$DUST_BIN" >/dev/null 2>&1; then
      "$DUST_BIN" -j -d 1000 -n 1000000 / >"$DISK_TREE_FILE" 2>/dev/null || echo '[]' >"$DISK_TREE_FILE"
    elif command -v ncdu >/dev/null 2>&1; then
      sudo ncdu -o "$DISK_TREE_FILE" --exclude-kernfs -e -0 / 2>/dev/null || echo '[]' >"$DISK_TREE_FILE"
    else
      echo '[]' >"$DISK_TREE_FILE"
    fi
    ;;

  "macOS")
    ENV_JSON=$(jq -c -n \
      --arg os "macOS" \
      --arg arch "${RUNNER_ARCH:-$(uname -m)}" \
      --arg name "${RUNNER_NAME:-unknown}" \
      --arg hostname "$(hostname)" \
      --arg kernel "$(uname -r)" \
      --arg uptime "$(uptime | awk '{print $3}' 2>/dev/null || echo '0')" \
      '{runner_os: $os, runner_arch: $arch, runner_name: $name, hostname: $hostname, kernel: $kernel, uptime_seconds: $uptime}')

    STORAGE_JSON=$(diskutil list -plist 2>/dev/null | plutil -convert json -o - - 2>/dev/null | jq -c '.' || echo '{}')
    CPU_JSON=$(sysctl -a hw 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')
    HARDWARE_JSON=$(system_profiler -json SPHardwareDataType SPStorageDataType 2>/dev/null | jq -c '.' || echo '{}')

    if command -v "$DUST_BIN" >/dev/null 2>&1; then
      "$DUST_BIN" -j -d 1000 -n 1000000 / >"$DISK_TREE_FILE" 2>/dev/null || echo '[]' >"$DISK_TREE_FILE"
    else
      echo '[]' >"$DISK_TREE_FILE"
    fi
    ;;

  "Windows")
    ENV_JSON=$(pwsh -Command "[PSCustomObject]@{runner_os='Windows'; runner_arch='${RUNNER_ARCH:-X64}'; runner_name='${RUNNER_NAME:-unknown}'; hostname='$(hostname)'; kernel='$(uname -r)'} | ConvertTo-Json -Compress" 2>/dev/null || echo '{}')
    STORAGE_JSON=$(pwsh -Command "Get-Volume | Select-Object DriveLetter, FileSystemType, SizeRemaining, Size | ConvertTo-Json -Compress" 2>/dev/null || echo '[]')
    CPU_JSON=$(pwsh -Command "Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors | ConvertTo-Json -Compress" 2>/dev/null || echo '[]')
    HARDWARE_JSON=$(pwsh -Command "Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, TotalPhysicalMemory | ConvertTo-Json -Compress" 2>/dev/null || echo '{}')

    if command -v "$DUST_BIN" >/dev/null 2>&1; then
      "$DUST_BIN" -j -d 1000 -n 1000000 C:\\ >"$DISK_TREE_FILE" 2>/dev/null || echo '[]' >"$DISK_TREE_FILE"
    else
      echo '[]' >"$DISK_TREE_FILE"
    fi
    ;;
esac

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
  emit_gha_output "disk_tree_path" "${DISK_TREE_FILE}"
fi
