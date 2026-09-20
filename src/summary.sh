#!/bin/sh
set -euC

OUT_DIR="${RUNNER_TEMP:-/tmp}/runner-fetch"
PID_FILE="${OUT_DIR}/monitor.pid"
SAMPLES_FILE="${OUT_DIR}/samples.tsv"
SUMMARY_FILE="${OUT_DIR}/summary.json"
PROM_FILE="${OUT_DIR}/metrics.prom"
CHART_FILE="${OUT_DIR}/chart.mermaid"

# 1. Stop background monitor daemon if running
if [ -f "$PID_FILE" ]; then
	MONITOR_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
	if [ -n "$MONITOR_PID" ]; then
		kill -TERM "$MONITOR_PID" 2>/dev/null || true
		if [ "${RUNNER_OS:-Linux}" = "Windows" ]; then
			taskkill //F //PID "$MONITOR_PID" >/dev/null 2>&1 || true
		fi
	fi
	rm -f "$PID_FILE"
fi

# Allow a moment for monitor to flush last write
sleep 1

if [ "${INPUT_MONITOR:-true}" = "false" ]; then
	exit 0
fi

if [ ! -f "$SAMPLES_FILE" ] || [ "$(wc -l <"$SAMPLES_FILE")" -le 1 ]; then
	echo "Runner telemetry: no samples collected (job completed before sample interval)."
	exit 0
fi

TARGET_OS="${RUNNER_OS:-Linux}"
RUNNER_NAME="${RUNNER_NAME:-unknown}"
PROM_TARGET=""
[ "${INPUT_EXPORT_PROMETHEUS:-true}" = "true" ] && PROM_TARGET="$PROM_FILE"

# Truncate output files safely under noclobber (set -C)
: >|"$CHART_FILE"
[ -n "$PROM_TARGET" ] && : >|"$PROM_TARGET"

# 2. Single-pass awk processor: Aggregates metrics, formats sparklines, generates Mermaid chart & Prometheus export
STATS=$(awk -F'\t' -v rname="$RUNNER_NAME" -v prom_file="$PROM_TARGET" -v chart_file="$CHART_FILE" '
function get_spark(hist, n, max_val,    res, i, step, pts, v, idx) {
	if (n < 1) return "—"
	pts = (n > 30 ? 30 : n)
	step = (n > 30 ? n / 30 : 1)
	res = ""
	for (i = 0; i < pts; i++) {
		idx = int(1 + i * step)
		if (idx > n) idx = n
		v = (max_val > 0 ? (hist[idx] * 100 / max_val) : hist[idx])
		if (v < 0) v = 0
		if (v > 100) v = 100
		res = res blocks[int(v * 7 / 100)]
	}
	return res
}

# Source of truth for Mermaid 50,000 max character limit:
# https://github.com/mermaid-js/mermaid/blob/develop/packages/mermaid/src/defaultConfig.ts#L41
# Official xyChart documentation:
# https://mermaid.ai/open-source/syntax/xyChart.html
function build_mermaid(    dur, pts, p, s_idx, e_idx, j, max_c, max_m, c_val, m_val, m_c, m_m, w, h, reserved, cfg) {
	dur = (last_epoch > first_epoch ? (last_epoch - first_epoch) : 1)
	if (count < 2) {
		return "```mermaid\n" \
			"xychart\n" \
			"    title \"Resource Utilization Timeline\"\n" \
			"    x-axis \"Elapsed Time (s)\" 0 --> " dur "\n" \
			"    y-axis \"Percentage (%)\" 0 --> 100\n" \
			"    line \"CPU (%)\" [" int(cpu_hist[1]) "," int(cpu_hist[1]) "]\n" \
			"    line \"RAM (%)\" [" int(mem_hist[1] * 100 / tot_mem) "," int(mem_hist[1] * 100 / tot_mem) "]\n" \
			"```\n"
	}

	# Hard ceiling is 50,000 characters. With minified arrays [c1,c2,...] without spaces,
	# each point consumes at most ~6-8 characters total across both series.
	# Maximum safe points that will never exceed 49,000 characters: 6,000 points.
	# If count <= 6000: display 100% of every calculated point with zero downsampling.
	# If count > 6000: downsample into 6,000 buckets using peak preservation (max CPU & RAM per bucket).
	pts = (count > 6000 ? 6000 : count)

	# Dynamic canvas dimensions to maintain ~3.5:1 aspect ratio across point densities
	if (pts <= 150) {
		w = 950
		h = 380
		reserved = 70
	} else if (pts <= 600) {
		w = 1400
		h = 400
		reserved = 75
	} else if (pts <= 1500) {
		w = 2000
		h = 450
		reserved = 80
	} else if (pts <= 3500) {
		w = 3200
		h = 500
		reserved = 85
	} else {
		w = 5000
		h = 600
		reserved = 90
	}

	cfg = "%%{init:{\"xyChart\":{\"width\":" w ",\"height\":" h ",\"plotReservedSpacePercent\":" reserved "}}}%%\n"

	m_c = "line \"CPU (%)\" ["
	m_m = "line \"RAM (%)\" ["

	for (p = 0; p < pts; p++) {
		if (pts == count) {
			# 1:1 exact plotting without downsampling
			c_val = int(cpu_hist[p + 1])
			m_val = int(mem_hist[p + 1] * 100 / tot_mem)
		} else {
			# Peak-preserving bucket aggregation
			s_idx = int(1 + p * (count - 1) / (pts - 1))
			e_idx = int(1 + (p + 1) * (count - 1) / (pts - 1))
			if (e_idx > count) e_idx = count
			max_c = 0
			max_m = 0
			for (j = s_idx; j <= e_idx; j++) {
				if (cpu_hist[j] > max_c) max_c = cpu_hist[j]
				if (mem_hist[j] > max_m) max_m = mem_hist[j]
			}
			c_val = int(max_c)
			m_val = int(max_m * 100 / tot_mem)
		}

		if (c_val < 0) c_val = 0
		if (c_val > 100) c_val = 100
		if (m_val < 0) m_val = 0
		if (m_val > 100) m_val = 100

		if (p == 0) {
			m_c = m_c c_val
			m_m = m_m m_val
		} else {
			m_c = m_c "," c_val
			m_m = m_m "," m_val
		}
	}
	m_c = m_c "]"
	m_m = m_m "]"

	return "```mermaid\n" cfg \
		"xychart\n" \
		"    title \"Resource Utilization Timeline\"\n" \
		"    x-axis \"Elapsed Time (s)\" 0 --> " dur "\n" \
		"    y-axis \"Percentage (%)\" 0 --> 100\n" \
		"    " m_c "\n" \
		"    " m_m "\n" \
		"```\n"
}

BEGIN {
	blocks[0] = " "
	blocks[1] = "▂"
	blocks[2] = "▃"
	blocks[3] = "▄"
	blocks[4] = "▅"
	blocks[5] = "▆"
	blocks[6] = "▇"
	blocks[7] = "█"

	if (prom_file != "") {
		print "# HELP runner_cpu_percent Total CPU usage percentage" > prom_file
		print "# TYPE runner_cpu_percent gauge" >> prom_file
		print "# HELP runner_cpu_user_percent User space CPU percentage" >> prom_file
		print "# TYPE runner_cpu_user_percent gauge" >> prom_file
		print "# HELP runner_cpu_system_percent Kernel space CPU percentage" >> prom_file
		print "# TYPE runner_cpu_system_percent gauge" >> prom_file
		print "# HELP runner_cpu_steal_percent Hypervisor steal CPU percentage" >> prom_file
		print "# TYPE runner_cpu_steal_percent gauge" >> prom_file
		print "# HELP runner_memory_used_bytes Memory used in bytes" >> prom_file
		print "# TYPE runner_memory_used_bytes gauge" >> prom_file
		print "# HELP runner_memory_available_bytes Memory available in bytes" >> prom_file
		print "# TYPE runner_memory_available_bytes gauge" >> prom_file
		print "# HELP runner_disk_free_bytes Free disk space in bytes" >> prom_file
		print "# TYPE runner_disk_free_bytes gauge" >> prom_file
	}
}

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

	t_hist[count] = epoch
	cpu_hist[count] = tot
	mem_hist[count] = m_used

	if (prom_file != "") {
		ts = epoch "000"
		printf "runner_cpu_percent{runner=\"%s\"} %s %s\n", rname, tot, ts >> prom_file
		printf "runner_cpu_user_percent{runner=\"%s\"} %s %s\n", rname, u, ts >> prom_file
		printf "runner_cpu_system_percent{runner=\"%s\"} %s %s\n", rname, s, ts >> prom_file
		printf "runner_cpu_steal_percent{runner=\"%s\"} %s %s\n", rname, st, ts >> prom_file
		printf "runner_memory_used_bytes{runner=\"%s\"} %d %s\n", rname, (m_used * 1048576), ts >> prom_file
		printf "runner_memory_available_bytes{runner=\"%s\"} %d %s\n", rname, (m_avail * 1048576), ts >> prom_file
		printf "runner_disk_free_bytes{runner=\"%s\",mount=\"/\"} %d %s\n", rname, (d_free * 1048576), ts >> prom_file
	}
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

	if (chart_file != "") {
		printf "%s", build_mermaid() > chart_file
	}

	printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n",
		count, duration, avg_cpu, peak_cpu, max_steal,
		m_init, peak_mem, m_final, tot_mem, peak_mem_pct,
		d_consumed, oom_count,
		get_spark(cpu_hist, count, 100),
		get_spark(mem_hist, count, tot_mem)
}' "$SAMPLES_FILE")

IFS='	' read -r SAMPLE_COUNT DURATION_SEC CPU_AVG CPU_PEAK CPU_STEAL_MAX \
	MEM_INIT_MB MEM_PEAK_MB MEM_FINAL_MB MEM_TOTAL_MB MEM_PEAK_PCT \
	DISK_CONSUMED_MB OOM_COUNT CPU_SPARKLINE MEM_SPARKLINE <<EOF
$STATS
EOF

# 3. Kernel OOM Check
OOM_DETECTED="false"
OOM_DETAILS=""

if [ "$OOM_COUNT" -gt 0 ]; then
	OOM_DETECTED="true"
	OOM_DETAILS="Kernel recorded ${OOM_COUNT} process kill event(s)."
fi

if [ "$OOM_DETECTED" = "false" ] && [ "$TARGET_OS" = "Linux" ]; then
	CGPATH=$(awk -F: '$1 == 0 {print $3}' /proc/self/cgroup 2>/dev/null || echo "")
	CG_EVENTS=""
	[ -n "$CGPATH" ] && [ -r "/sys/fs/cgroup${CGPATH}/memory.events" ] && CG_EVENTS="/sys/fs/cgroup${CGPATH}/memory.events"
	[ -z "$CG_EVENTS" ] && [ -r /sys/fs/cgroup/memory.events ] && CG_EVENTS="/sys/fs/cgroup/memory.events"

	if [ -n "$CG_EVENTS" ]; then
		CGROUP_OOM=$(awk '/oom_kill / {print $2}' "$CG_EVENTS" 2>/dev/null || echo 0)
		if [ "$CGROUP_OOM" -gt 0 ]; then
			OOM_DETECTED="true"
			OOM_DETAILS="Cgroup memory.events confirmed ${CGROUP_OOM} OOM kill(s)."
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

echo "$SUMMARY_JSON" >|"$SUMMARY_FILE"

# 5. Write to $GITHUB_STEP_SUMMARY
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
		echo "| Metric | Baseline / Min | Peak / Max | Final / Avg | Trend |"
		echo "| :--- | :--- | :--- | :--- | :--- |"
		echo "| **CPU Utilization** | — | **${CPU_PEAK}%** | Avg: **${CPU_AVG}%** | \`${CPU_SPARKLINE}\` |"
		echo "| **Memory Usage** | ${MEM_INIT_MB} MB | **${MEM_PEAK_MB} MB** (${MEM_PEAK_PCT}%) | ${MEM_FINAL_MB} MB / ${MEM_TOTAL_MB} MB | \`${MEM_SPARKLINE}\` |"
		echo "| **Disk Consumed** | — | Net: **${DISK_CONSUMED_MB} MB** | — | — |"
		[ "$CPU_STEAL_MAX" -gt 0 ] && echo "| **CPU Steal (Contention)** | — | **${CPU_STEAL_MAX}%** ⚠️ | Hypervisor throttling detected | — |"
		echo ""
		echo "### Resource Utilization Timeline"
		echo ""
		cat "$CHART_FILE"
		echo ""
		echo "*Duration: ${DURATION_SEC}s (${SAMPLE_COUNT} samples)*"
		echo ""
	} >>"$GITHUB_STEP_SUMMARY"
fi

# 6. Set Action Outputs
if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		printf "peak_memory_mb=%s\n" "$MEM_PEAK_MB"
		printf "avg_cpu_percent=%s\n" "$CPU_AVG"
		printf "disk_consumed_mb=%s\n" "$DISK_CONSUMED_MB"
		printf "oom_detected=%s\n" "$OOM_DETECTED"
		printf 'summary<<EOF_SUMMARY\n%s\nEOF_SUMMARY\n' "$SUMMARY_JSON"
	} >>"$GITHUB_OUTPUT"
fi
