#!/bin/sh
set -euC

OUT_DIR="${RUNNER_TEMP:-/tmp}/runner-fetch"
mkdir -p "$OUT_DIR"
PID_FILE="${OUT_DIR}/monitor.pid"
SAMPLES_FILE="${OUT_DIR}/samples.tsv"
SAMPLE_INTERVAL="${INPUT_SAMPLE_INTERVAL:-2}"

echo "$$" >|"$PID_FILE"
trap 'exit 0' TERM INT QUIT HUP

TARGET_OS="${RUNNER_OS:-Linux}"

if [ ! -f "$SAMPLES_FILE" ]; then
	printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\n" >|"$SAMPLES_FILE"
fi

# Pre-resolve OOM kill source once before loop (Linux only)
OOM_SRC=""
if [ "$TARGET_OS" = "Linux" ]; then
	CGPATH=$(awk -F: '$1 == 0 {print $3}' /proc/self/cgroup 2>/dev/null || echo "")
	if [ -n "$CGPATH" ] && [ -r "/sys/fs/cgroup${CGPATH}/memory.events" ]; then
		OOM_SRC="/sys/fs/cgroup${CGPATH}/memory.events"
	elif [ -r /sys/fs/cgroup/memory.events ]; then
		OOM_SRC="/sys/fs/cgroup/memory.events"
	elif [ -r /proc/vmstat ]; then
		OOM_SRC="/proc/vmstat"
	fi
fi

# Pre-resolve target mount point for disk monitoring (inspects actual workspace/temp NVMe on large runners)
TARGET_DISK_DIR="${GITHUB_WORKSPACE:-${RUNNER_TEMP:-/}}"

# Hoist invariant Darwin hardware specifications outside loop
HW_MEMSIZE=0
HW_PAGESIZE=4096
if [ "$TARGET_OS" = "macOS" ]; then
	HW_MEMSIZE=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
	HW_PAGESIZE=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
fi

PREV_USER=0
PREV_NICE=0
PREV_SYS=0
PREV_IDLE=0
PREV_IOWAIT=0
PREV_STEAL=0

ENABLE_CPU="${INPUT_MONITOR_CPU:-true}"
ENABLE_MEM="${INPUT_MONITOR_MEMORY:-true}"
ENABLE_DISK="${INPUT_MONITOR_DISK:-false}"

if [ "$ENABLE_CPU" = "false" ] && [ "$ENABLE_MEM" = "false" ] && [ "$ENABLE_DISK" = "false" ]; then
	exit 0
fi

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

	# 1. Target filesystem free disk space (actual workspace mount across all platforms)
	if [ "$ENABLE_DISK" = "true" ]; then
		DISK_FREE_MB=$(df -k "$TARGET_DISK_DIR" 2>/dev/null | awk 'NR==2 {print int($4/1024)}' || echo 0)
	fi

	# 2. Memory metrics: /proc/meminfo is shared between Linux and Windows (MSYS/Git Bash)
	if [ "$ENABLE_MEM" = "true" ]; then
		if [ -r /proc/meminfo ]; then
			MEM_TOTAL_KB=0
			MEM_AVAIL_KB=0
			while read -r key val _; do
				case "$key" in
				MemTotal:) MEM_TOTAL_KB=$val ;;
				MemAvailable:) MEM_AVAIL_KB=$val ;;
				MemFree:) [ "$MEM_AVAIL_KB" -eq 0 ] && MEM_AVAIL_KB=$val ;;
				esac
			done </proc/meminfo
			if [ "$MEM_TOTAL_KB" -gt 0 ]; then
				MEM_USED_MB=$(((MEM_TOTAL_KB - MEM_AVAIL_KB) / 1024))
				MEM_AVAIL_MB=$((MEM_AVAIL_KB / 1024))
			fi
		fi
	fi

	# 3. Platform-specific CPU and OOM metrics
	case "$TARGET_OS" in
	"Linux")
		if [ "$ENABLE_CPU" = "true" ] && [ -r /proc/stat ]; then
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

		if [ "$ENABLE_MEM" = "true" ] && [ -n "$OOM_SRC" ]; then
			OOM_KILLS=$(awk '/oom_kill / {print $2}' "$OOM_SRC" 2>/dev/null || echo 0)
		fi
		;;

	"macOS")
		if [ "$ENABLE_MEM" = "true" ]; then
			MEM_AVAIL_PAGES=$(vm_stat 2>/dev/null | awk -F: '/Pages (free|speculative):/ { sub(/[. \t\r]+$/, "", $2); s += $2 } END { print s+0 }')
			MEM_AVAIL_MB=$(((MEM_AVAIL_PAGES * HW_PAGESIZE) / 1048576))
			if [ "$HW_MEMSIZE" -gt 0 ]; then
				MEM_USED_MB=$(((HW_MEMSIZE / 1048576) - MEM_AVAIL_MB))
			fi
		fi
		if [ "$ENABLE_CPU" = "true" ]; then
			CPU_TOTAL=$(top -l 1 -n 0 -F -R 2>/dev/null | awk -F'[:,%]' '/CPU usage:/ {print int($2 + $4)}' || echo 0)
		fi
		;;

	"Windows")
		if [ "$ENABLE_CPU" = "true" ] && [ -r /proc/loadavg ]; then
			CPU_TOTAL=$(awk '{print int($1 * 100)}' /proc/loadavg 2>/dev/null || echo 0)
		fi
		;;
	esac

	printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
		"$EPOCH" "$CPU_USER" "$CPU_SYS" "$CPU_STEAL" "$CPU_IOWAIT" "$CPU_TOTAL" \
		"$MEM_USED_MB" "$MEM_AVAIL_MB" "$DISK_FREE_MB" "$OOM_KILLS" >>"$SAMPLES_FILE"

	sleep "$SAMPLE_INTERVAL"
done
