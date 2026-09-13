#!/bin/sh
set -eu

OUT_DIR="${RUNNER_TEMP:-/tmp}/runner-fetch"
PID_FILE="${OUT_DIR}/monitor.pid"
SAMPLES_FILE="${OUT_DIR}/samples.tsv"
SUMMARY_FILE="${OUT_DIR}/summary.json"
PROM_FILE="${OUT_DIR}/metrics.prom"
SVG_FILE="${OUT_DIR}/resource_chart.svg"

# 1. Stop background monitor daemon if running
if [ -f "$PID_FILE" ]; then
  MONITOR_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$MONITOR_PID" ]; then
    kill -TERM "$MONITOR_PID" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
fi

# Allow a moment for monitor to flush last write
sleep 1

if [ "${INPUT_MONITOR:-true}" = "false" ]; then
  exit 0
fi

if [ ! -f "$SAMPLES_FILE" ] || [ "$(wc -l <"$SAMPLES_FILE")" -le 1 ]; then
  echo "::warning::No runner telemetry samples were collected."
  exit 0
fi

TARGET_OS="${RUNNER_OS:-Linux}"
RUNNER_NAME="${RUNNER_NAME:-unknown}"

# 2. Process samples using awk (single pass for speed and efficiency)
STATS=$(awk -F'\t' '
NR > 1 {
	count++
	epoch = $1
	u = $2; s = $3; st = $4; io = $5; tot = $6
	m_used = $7; m_avail = $8; d_free = $9; oom = $10

	if (count == 1) {
		first_epoch = epoch
		m_init = m_used
		d_init = d_free
		peak_mem = m_used
		peak_cpu = tot
		max_steal = st
	}

	cpu_sum += tot
	if (tot > peak_cpu) peak_cpu = tot
	if (st > max_steal) max_steal = st
	if (m_used > peak_mem) peak_mem = m_used
	if (oom > 0) oom_count += oom

	last_epoch = epoch
	m_final = m_used
	d_final = d_free
	last_avail = m_avail
}
END {
	if (count == 0) count = 1
	avg_cpu = int(cpu_sum / count)
	duration = last_epoch - first_epoch
	d_consumed = d_init - d_final
	if (d_consumed < 0) d_consumed = 0
	tot_mem = peak_mem + last_avail
	if (tot_mem == 0) tot_mem = 1
	peak_mem_pct = int((peak_mem * 100) / tot_mem)

	printf "%d %d %d %d %d %d %d %d %d %d %d %d\n",
		count, duration, avg_cpu, peak_cpu, max_steal,
		m_init, peak_mem, m_final, tot_mem, peak_mem_pct,
		d_consumed, oom_count
}' "$SAMPLES_FILE")

# shellcheck disable=SC2086
set -- $STATS
SAMPLE_COUNT=$1
DURATION_SEC=$2
CPU_AVG=$3
CPU_PEAK=$4
CPU_STEAL_MAX=$5
MEM_INIT_MB=$6
MEM_PEAK_MB=$7
MEM_FINAL_MB=$8
MEM_TOTAL_MB=$9
shift 9
MEM_PEAK_PCT=$1
DISK_CONSUMED_MB=$2
OOM_COUNT=$3

# 3. Kernel OOM Check
OOM_DETECTED="false"
OOM_DETAILS=""

if [ "$OOM_COUNT" -gt 0 ]; then
  OOM_DETECTED="true"
  OOM_DETAILS="Kernel recorded ${OOM_COUNT} process kill event(s)."
fi

if [ "$OOM_DETECTED" = "false" ] && [ "$TARGET_OS" = "Linux" ]; then
  CGPATH=$(awk -F: '$1 == 0 {print $3}' /proc/self/cgroup 2>/dev/null || echo "")
  if [ -n "$CGPATH" ] && [ -r "/sys/fs/cgroup${CGPATH}/memory.events" ]; then
    CGROUP_OOM=$(awk '/oom_kill / {print $2}' "/sys/fs/cgroup${CGPATH}/memory.events" 2>/dev/null || echo 0)
    if [ "$CGROUP_OOM" -gt 0 ]; then
      OOM_DETECTED="true"
      OOM_DETAILS="Cgroup memory.events confirmed ${CGROUP_OOM} OOM kill(s)."
    fi
  elif [ -r /sys/fs/cgroup/memory.events ]; then
    CGROUP_OOM=$(awk '/oom_kill / {print $2}' /sys/fs/cgroup/memory.events 2>/dev/null || echo 0)
    if [ "$CGROUP_OOM" -gt 0 ]; then
      OOM_DETECTED="true"
      OOM_DETAILS="Cgroup v2 memory.events confirmed ${CGROUP_OOM} OOM kill(s)."
    fi
  fi
  if [ "$OOM_DETECTED" = "false" ] && [ -r /proc/vmstat ]; then
    VMSTAT_OOM=$(awk '/oom_kill / {print $2}' /proc/vmstat 2>/dev/null || echo 0)
    if [ "$VMSTAT_OOM" -gt 0 ]; then
      OOM_DETECTED="true"
      OOM_DETAILS="/proc/vmstat recorded ${VMSTAT_OOM} kernel OOM kill(s)."
    fi
  fi
  if [ "$OOM_DETECTED" = "false" ] && command -v dmesg >/dev/null 2>&1; then
    DMESG_OOM=$(dmesg 2>/dev/null | grep -iE 'killed process|out of memory: killed' | tail -n 1 || true)
    if [ -n "$DMESG_OOM" ]; then
      OOM_DETECTED="true"
      OOM_DETAILS="${DMESG_OOM}"
    fi
  fi
fi

# 4. Generate summary.json (Single Source of Truth)
ESCAPED_OOM_DETAILS=$(printf '%s' "$OOM_DETAILS" | tr '\r\n\t' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
SUMMARY_JSON=$(printf '{"duration_seconds":%d,"samples_count":%d,"cpu":{"average_percent":%d,"peak_percent":%d,"max_steal_percent":%d},"memory":{"initial_mb":%d,"peak_mb":%d,"final_mb":%d,"total_mb":%d,"peak_percent":%d},"disk":{"consumed_mb":%d},"oom_detected":%s,"oom_details":"%s"}' \
  "$DURATION_SEC" "$SAMPLE_COUNT" \
  "$CPU_AVG" "$CPU_PEAK" "$CPU_STEAL_MAX" \
  "$MEM_INIT_MB" "$MEM_PEAK_MB" "$MEM_FINAL_MB" "$MEM_TOTAL_MB" "$MEM_PEAK_PCT" \
  "$DISK_CONSUMED_MB" "$OOM_DETECTED" "$ESCAPED_OOM_DETAILS")

echo "$SUMMARY_JSON" >"$SUMMARY_FILE"

# 5. Generate OpenMetrics / Prometheus export (.prom)
if [ "${INPUT_EXPORT_PROMETHEUS:-true}" = "true" ]; then
  awk -F'\t' -v rname="$RUNNER_NAME" '
	BEGIN {
		print "# HELP runner_cpu_percent Total CPU usage percentage"
		print "# TYPE runner_cpu_percent gauge"
		print "# HELP runner_cpu_user_percent User space CPU percentage"
		print "# TYPE runner_cpu_user_percent gauge"
		print "# HELP runner_cpu_system_percent Kernel space CPU percentage"
		print "# TYPE runner_cpu_system_percent gauge"
		print "# HELP runner_cpu_steal_percent Hypervisor steal CPU percentage"
		print "# TYPE runner_cpu_steal_percent gauge"
		print "# HELP runner_memory_used_bytes Memory used in bytes"
		print "# TYPE runner_memory_used_bytes gauge"
		print "# HELP runner_memory_available_bytes Memory available in bytes"
		print "# TYPE runner_memory_available_bytes gauge"
		print "# HELP runner_disk_free_bytes Free disk space in bytes"
		print "# TYPE runner_disk_free_bytes gauge"
	}
	NR > 1 {
		ts = $1 "000"
		printf "runner_cpu_percent{runner=\"%s\"} %s %s\n", rname, $6, ts
		printf "runner_cpu_user_percent{runner=\"%s\"} %s %s\n", rname, $2, ts
		printf "runner_cpu_system_percent{runner=\"%s\"} %s %s\n", rname, $3, ts
		printf "runner_cpu_steal_percent{runner=\"%s\"} %s %s\n", rname, $4, ts
		printf "runner_memory_used_bytes{runner=\"%s\"} %d %s\n", rname, ($7 * 1048576), ts
		printf "runner_memory_available_bytes{runner=\"%s\"} %d %s\n", rname, ($8 * 1048576), ts
		printf "runner_disk_free_bytes{runner=\"%s\",mount=\"/\"} %d %s\n", rname, ($9 * 1048576), ts
	}
	' "$SAMPLES_FILE" >"$PROM_FILE"
fi

# 6. Generate lightweight SVG Sparkline Charts
CPU_POINTS=$(awk -F'\t' 'NR > 1 {printf "%d ", $6}' "$SAMPLES_FILE")
MEM_POINTS=$(awk -F'\t' -v tot="$MEM_TOTAL_MB" 'NR > 1 { pct = int(($7 * 100) / (tot > 0 ? tot : 1)); printf "%d ", pct }' "$SAMPLES_FILE")

CPU_POLYLINE=$(echo "$CPU_POINTS" | awk '
{
	n = NF
	if (n < 2) n = 2
	for (i = 1; i <= NF; i++) {
		x = int((i - 1) * 480 / (n - 1)) + 10
		val = $i
		if (val > 100) val = 100
		y = 85 - int(val * 70 / 100)
		printf "%d,%d ", x, y
	}
}')

MEM_POLYLINE=$(echo "$MEM_POINTS" | awk '
{
	n = NF
	if (n < 2) n = 2
	for (i = 1; i <= NF; i++) {
		x = int((i - 1) * 480 / (n - 1)) + 10
		val = $i
		if (val > 100) val = 100
		y = 85 - int(val * 70 / 100)
		printf "%d,%d ", x, y
	}
}')

cat <<EOF >"$SVG_FILE"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 500 100" width="100%" height="100">
  <rect width="500" height="100" fill="#0d1117" rx="6"/>
  <line x1="10" y1="15" x2="490" y2="15" stroke="#30363d" stroke-dasharray="2"/>
  <line x1="10" y1="50" x2="490" y2="50" stroke="#30363d" stroke-dasharray="2"/>
  <line x1="10" y1="85" x2="490" y2="85" stroke="#30363d"/>
  <text x="14" y="27" fill="#8b949e" font-size="10" font-family="sans-serif">100%</text>
  <text x="14" y="62" fill="#8b949e" font-size="10" font-family="sans-serif">50%</text>
  <text x="14" y="82" fill="#8b949e" font-size="10" font-family="sans-serif">0%</text>
  <polyline fill="none" stroke="#58a6ff" stroke-width="2" points="${CPU_POLYLINE}" />
  <polyline fill="none" stroke="#f778ba" stroke-width="2" points="${MEM_POLYLINE}" />
  <circle cx="340" cy="18" r="4" fill="#58a6ff"/>
  <text x="350" y="21" fill="#c9d1d9" font-size="10" font-family="sans-serif">CPU %</text>
  <circle cx="420" cy="18" r="4" fill="#f778ba"/>
  <text x="430" y="21" fill="#c9d1d9" font-size="10" font-family="sans-serif">RAM %</text>
</svg>
EOF

# 7. Write to $GITHUB_STEP_SUMMARY
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## 📊 Runner Telemetry & Resource Summary"
    echo ""
    if [ "$OOM_DETECTED" = "true" ]; then
      echo "> [!CAUTION]"
      echo "> **Out-Of-Memory (OOM) Kill Detected!**"
      echo "> The Linux kernel terminated one or more processes due to memory exhaustion."
      [ -n "$OOM_DETAILS" ] && echo "> Details: \`${OOM_DETAILS}\`"
      echo ""
    fi
    echo "| Metric | Baseline / Min | Peak / Max | Final / Avg |"
    echo "| :--- | :--- | :--- | :--- |"
    echo "| **CPU Utilization** | — | **${CPU_PEAK}%** | Avg: **${CPU_AVG}%** |"
    echo "| **Memory Usage** | ${MEM_INIT_MB} MB | **${MEM_PEAK_MB} MB** (${MEM_PEAK_PCT}%) | ${MEM_FINAL_MB} MB / ${MEM_TOTAL_MB} MB |"
    echo "| **Disk Consumed** | — | Net: **${DISK_CONSUMED_MB} MB** | — |"
    [ "$CPU_STEAL_MAX" -gt 0 ] && echo "| **CPU Steal (Contention)** | — | **${CPU_STEAL_MAX}%** ⚠️ | Hypervisor throttling detected |"
    echo ""
    echo "### Resource Utilization Timeline"
    echo ""
    cat "$SVG_FILE"
    echo ""
    echo "*Blue = CPU % | Pink = RAM % | Duration = ${DURATION_SEC}s (${SAMPLE_COUNT} samples)*"
    echo ""
  } >>"$GITHUB_STEP_SUMMARY"
fi

# 8. Set Action Outputs
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf "peak_memory_mb=%s\n" "$MEM_PEAK_MB"
    printf "avg_cpu_percent=%s\n" "$CPU_AVG"
    printf "disk_consumed_mb=%s\n" "$DISK_CONSUMED_MB"
    printf "oom_detected=%s\n" "$OOM_DETECTED"
    printf 'summary<<EOF_SUMMARY\n%s\nEOF_SUMMARY\n' "$SUMMARY_JSON"
  } >>"$GITHUB_OUTPUT"
fi
