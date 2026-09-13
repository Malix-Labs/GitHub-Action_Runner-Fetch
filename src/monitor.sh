#!/bin/sh
set -euC

OUT_DIR="${RUNNER_TEMP:-/tmp}/runner-fetch"
mkdir -p "$OUT_DIR"
PID_FILE="${OUT_DIR}/monitor.pid"
SAMPLES_FILE="${OUT_DIR}/samples.tsv"
SAMPLE_INTERVAL="${INPUT_SAMPLE_INTERVAL:-2}"

echo "$$" >|"$PID_FILE"

# Clean exit on termination signals
trap 'exit 0' TERM INT QUIT HUP

TARGET_OS="${RUNNER_OS:-Linux}"

# Write TSV header if file does not exist
if [ ! -f "$SAMPLES_FILE" ]; then
  printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\n" >|"$SAMPLES_FILE"
fi

PREV_USER=0
PREV_NICE=0
PREV_SYS=0
PREV_IDLE=0
PREV_IOWAIT=0
PREV_STEAL=0

while :; do
  EPOCH=$(date +%s)
  CPU_USER=0
  CPU_SYS=0
  CPU_STEAL=0
  CPU_IOWAIT=0
  CPU_TOTAL=0
  MEM_USED_MB=0
  MEM_AVAIL_MB=0
  DISK_FREE_MB=0
  OOM_KILLS=0

  case "$TARGET_OS" in
  "Linux")
    # 1. CPU metrics from /proc/stat
    if [ -r /proc/stat ]; then
      read -r _ USER NICE SYS IDLE IOWAIT _ _ STEAL _ </proc/stat

      D_USER=$((USER - PREV_USER))
      D_NICE=$((NICE - PREV_NICE))
      D_SYS=$((SYS - PREV_SYS))
      D_IDLE=$((IDLE - PREV_IDLE))
      D_IOWAIT=$((IOWAIT - PREV_IOWAIT))
      D_STEAL=$((STEAL - PREV_STEAL))

      D_TOTAL=$((D_USER + D_NICE + D_SYS + D_IDLE + D_IOWAIT + D_STEAL))

      if [ "$D_TOTAL" -gt 0 ] && [ "$PREV_USER" -gt 0 ]; then
        CPU_USER=$(((D_USER + D_NICE) * 100 / D_TOTAL))
        CPU_SYS=$((D_SYS * 100 / D_TOTAL))
        CPU_IOWAIT=$((D_IOWAIT * 100 / D_TOTAL))
        CPU_STEAL=$((D_STEAL * 100 / D_TOTAL))
        CPU_TOTAL=$(((D_TOTAL - D_IDLE) * 100 / D_TOTAL))
      fi

      PREV_USER=$USER
      PREV_NICE=$NICE
      PREV_SYS=$SYS
      PREV_IDLE=$IDLE
      PREV_IOWAIT=$IOWAIT
      PREV_STEAL=$STEAL
    fi

    # 2. Memory metrics from /proc/meminfo
    if [ -r /proc/meminfo ]; then
      MEM_TOTAL_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo || echo 0)
      MEM_AVAIL_KB=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo || awk '/MemFree:/ {print $2}' /proc/meminfo || echo 0)
      if [ "$MEM_TOTAL_KB" -gt 0 ]; then
        MEM_USED_KB=$((MEM_TOTAL_KB - MEM_AVAIL_KB))
        MEM_USED_MB=$((MEM_USED_KB / 1024))
        MEM_AVAIL_MB=$((MEM_AVAIL_KB / 1024))
      fi
    fi

    # 3. Disk free on root filesystem in MB
    DISK_FREE_MB=$(df -k / 2>/dev/null | awk 'NR==2 {print int($4/1024)}' || echo 0)

    # 4. OOM kills counter (cgroup v2 process scope, cgroup v2 root, or /proc/vmstat)
    CGPATH=$(awk -F: '$1 == 0 {print $3}' /proc/self/cgroup 2>/dev/null || echo "")
    if [ -n "$CGPATH" ] && [ -r "/sys/fs/cgroup${CGPATH}/memory.events" ]; then
      OOM_KILLS=$(awk '/oom_kill / {print $2}' "/sys/fs/cgroup${CGPATH}/memory.events" 2>/dev/null || echo 0)
    elif [ -r /sys/fs/cgroup/memory.events ]; then
      OOM_KILLS=$(awk '/oom_kill / {print $2}' /sys/fs/cgroup/memory.events 2>/dev/null || echo 0)
    elif [ -r /proc/vmstat ]; then
      OOM_KILLS=$(awk '/oom_kill / {print $2}' /proc/vmstat 2>/dev/null || echo 0)
    fi
    ;;

  "macOS")
    # Disk free on root
    DISK_FREE_MB=$(df -k / 2>/dev/null | awk 'NR==2 {print int($4/1024)}' || echo 0)

    # Memory using vm_stat
    PAGES_FREE=$(vm_stat 2>/dev/null | awk '/Pages free:/ {gsub("\\.",""); print $3}' || echo 0)
    PAGES_SPEC=$(vm_stat 2>/dev/null | awk '/Pages speculative:/ {gsub("\\.",""); print $3}' || echo 0)
    PAGE_SIZE=$(vm_stat 2>/dev/null | awk '/page size of/ {print $8}' || echo 4096)
    TOTAL_MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)

    AVAIL_BYTES=$(((PAGES_FREE + PAGES_SPEC) * PAGE_SIZE))
    MEM_AVAIL_MB=$((AVAIL_BYTES / 1048576))
    if [ "$TOTAL_MEM_BYTES" -gt 0 ]; then
      TOTAL_MEM_MB=$((TOTAL_MEM_BYTES / 1048576))
      MEM_USED_MB=$((TOTAL_MEM_MB - MEM_AVAIL_MB))
    fi

    # CPU usage via top sample
    CPU_TOTAL=$(top -l 1 -n 0 2>/dev/null | awk -F'[:,%]' '/CPU usage:/ {print int($2 + $4)}' || echo 0)
    ;;

  "Windows")
    # Windows / MINGW / MSYS environment
    DISK_FREE_MB=$(df -k / 2>/dev/null | awk 'NR==2 {print int($4/1024)}' || echo 0)
    ;;
  esac

  # Append row
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$EPOCH" "$CPU_USER" "$CPU_SYS" "$CPU_STEAL" "$CPU_IOWAIT" "$CPU_TOTAL" \
    "$MEM_USED_MB" "$MEM_AVAIL_MB" "$DISK_FREE_MB" "$OOM_KILLS" >>"$SAMPLES_FILE"

  sleep "$SAMPLE_INTERVAL"
done
