#!/bin/sh
set -euC

OUT_DIR="${RUNNER_TEMP:-/tmp}/runner-fetch"
mkdir -p "$OUT_DIR"
DISK_TREE_FILE="${OUT_DIR}/disk_tree.json"

TARGET_OS="${RUNNER_OS:-Linux}"

if ! command -v dust >/dev/null 2>&1; then
  DUST_TAG=$(curl -sL https://api.github.com/repos/bootandy/dust/releases/latest 2>/dev/null | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
  case "$TARGET_OS" in
  "Linux") curl -sL "https://github.com/bootandy/dust/releases/download/${DUST_TAG}/dust-${DUST_TAG}-$(uname -m)-unknown-linux-musl.tar.gz" | tar -xz --strip-components=1 -C "$OUT_DIR" 2>/dev/null || true ;;

  "macOS")
    MAC_ARCH="$(uname -m)"
    [ "$MAC_ARCH" = "arm64" ] && MAC_ARCH="aarch64"
    curl -sL "https://github.com/bootandy/dust/releases/download/${DUST_TAG}/dust-${DUST_TAG}-${MAC_ARCH}-apple-darwin.tar.gz" | tar -xz --strip-components=1 -C "$OUT_DIR" 2>/dev/null ||
      curl -sL "https://github.com/bootandy/dust/releases/download/${DUST_TAG}/dust-${DUST_TAG}-x86_64-apple-darwin.tar.gz" | tar -xz --strip-components=1 -C "$OUT_DIR" 2>/dev/null || true
    ;;

  "Windows") curl -sL "https://github.com/bootandy/dust/releases/download/${DUST_TAG}/dust-${DUST_TAG}-x86_64-pc-windows-msvc.zip" -o "${OUT_DIR}/dust.zip" 2>/dev/null && unzip -q -o -j "${OUT_DIR}/dust.zip" "*/dust.exe" -d "$OUT_DIR" 2>/dev/null && mv "${OUT_DIR}/dust.exe" "${OUT_DIR}/dust" 2>/dev/null || true ;;
  esac
fi

DUST_BIN="dust"
[ -f "${OUT_DIR}/dust" ] && DUST_BIN="${OUT_DIR}/dust"

TARGET_ROOT="/"

case "$TARGET_OS" in
"Linux")
  if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
  fi
  OS_NAME="${NAME:-Linux}"
  OS_VER="${VERSION_ID:-unknown}"
  OS_CODE="${VERSION_CODENAME:-unknown}"
  OS_PRETTY="${PRETTY_NAME:-Linux}"
  OS_ID="${ID:-linux}"

  TOOLCACHE_JSON=$(find "${RUNNER_TOOL_CACHE:-/opt/hostedtoolcache}" -mindepth 2 -maxdepth 2 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')
  PACKAGES_JSON=$(dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')

  ENV_JSON=$(jq -c -n \
    --arg os "Linux" \
    --arg os_name "$OS_NAME" \
    --arg os_version "$OS_VER" \
    --arg os_codename "$OS_CODE" \
    --arg os_pretty_name "$OS_PRETTY" \
    --arg os_id "$OS_ID" \
    --arg arch "${RUNNER_ARCH:-$(uname -m)}" \
    --arg name "${RUNNER_NAME:-unknown}" \
    --arg hostname "$(hostname)" \
    --arg kernel "$(uname -r)" \
    --arg uptime "$(awk '{print $1}' /proc/uptime 2>/dev/null || echo '0')" \
    --argjson toolcache "$TOOLCACHE_JSON" \
    --argjson packages "$PACKAGES_JSON" \
    '{runner_os: $os, os_name: $os_name, os_version: $os_version, os_codename: $os_codename, os_pretty_name: $os_pretty_name, os_id: $os_id, runner_arch: $arch, runner_name: $name, hostname: $hostname, kernel: $kernel, uptime_seconds: $uptime, toolcache: $toolcache, packages: $packages}')

  STORAGE_JSON=$(lsblk -b -O --json 2>/dev/null || echo '{"blockdevices":[]}')
  CPU_JSON=$(lscpu -B --json 2>/dev/null || echo '{"lscpu":[]}')
  HARDWARE_JSON=$(sudo lshw -json 2>/dev/null || echo '{}')
  OS_LABEL="${OS_NAME}-${OS_VER}"
  ;;

"macOS")
  TOOLCACHE_JSON=$(find "${RUNNER_TOOL_CACHE:-/Users/runner/hostedtoolcache}" -mindepth 2 -maxdepth 2 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')
  PACKAGES_JSON=$(brew list --versions 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')

  ENV_JSON=$(jq -c -n \
    --arg os "macOS" \
    --arg arch "${RUNNER_ARCH:-$(uname -m)}" \
    --arg name "${RUNNER_NAME:-unknown}" \
    --arg hostname "$(hostname)" \
    --arg kernel "$(uname -r)" \
    --arg uptime "$(uptime | awk '{print $3}' 2>/dev/null || echo '0')" \
    --argjson toolcache "$TOOLCACHE_JSON" \
    --argjson packages "$PACKAGES_JSON" \
    '{runner_os: $os, runner_arch: $arch, runner_name: $name, hostname: $hostname, kernel: $kernel, uptime_seconds: $uptime, toolcache: $toolcache, packages: $packages}')

  STORAGE_JSON=$(diskutil list -plist 2>/dev/null | plutil -convert json -o - - 2>/dev/null || echo '{}')
  CPU_JSON=$(sysctl -a hw 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length > 0))' || echo '[]')
  HARDWARE_JSON=$(system_profiler -json SPHardwareDataType SPStorageDataType 2>/dev/null || echo '{}')
  ;;

"Windows")
  # shellcheck disable=SC1003
  TARGET_ROOT='C:\'

  ENV_JSON=$(pwsh -Command "\$tc = Get-ChildItem C:\\hostedtoolcache\\* -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName; \$pkg = Get-ItemProperty HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\* -ErrorAction SilentlyContinue | Select-Object DisplayName, DisplayVersion; [PSCustomObject]@{runner_os='Windows'; runner_arch='${RUNNER_ARCH:-X64}'; runner_name='${RUNNER_NAME:-unknown}'; hostname='$(hostname)'; kernel='$(uname -r)'; toolcache=\$tc; packages=\$pkg} | ConvertTo-Json -Compress" 2>/dev/null || echo '{}')
  STORAGE_JSON=$(pwsh -Command "Get-Volume | Select-Object DriveLetter, FileSystemType, SizeRemaining, Size | ConvertTo-Json -Compress" 2>/dev/null || echo '[]')
  CPU_JSON=$(pwsh -Command "Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors | ConvertTo-Json -Compress" 2>/dev/null || echo '[]')
  HARDWARE_JSON=$(pwsh -Command "Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, TotalPhysicalMemory | ConvertTo-Json -Compress" 2>/dev/null || echo '{}')
  ;;
esac

ARTIFACT_NAME="disk-tree-${TARGET_OS}${OS_LABEL:+-${OS_LABEL}}-${RUNNER_ARCH:-$(uname -m)}"

if command -v "$DUST_BIN" >/dev/null 2>&1; then
  "$DUST_BIN" -j -d 1000 -n 10000000 "$TARGET_ROOT" >"$DISK_TREE_FILE" 2>/dev/null || echo '[]' >"$DISK_TREE_FILE"

elif command -v ncdu >/dev/null 2>&1; then
  sudo ncdu -o "$DISK_TREE_FILE" --exclude-kernfs -e -0 / 2>/dev/null || echo '[]' >"$DISK_TREE_FILE"
else
  echo '[]' >"$DISK_TREE_FILE"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  for item in "environment:${ENV_JSON}" "cpu:${CPU_JSON}" "storage:${STORAGE_JSON}" "hardware:${HARDWARE_JSON}" "disk_tree_path:${DISK_TREE_FILE}" "artifact_name:${ARTIFACT_NAME}"; do
    name="${item%%:*}"
    val="${item#*:}"
    printf '%s<<EOF_%s\n%s\nEOF_%s\n' "$name" "$name" "$val" "$name" >>"$GITHUB_OUTPUT"
    if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ "$name" != "disk_tree_path" ] && [ "$name" != "artifact_name" ]; then
      echo "::group::${name}"
      echo "${val}" | jq . 2>/dev/null || echo "${val}"
      echo "::endgroup::"
    fi
  done
fi
