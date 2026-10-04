#!/bin/sh
set -euC

OUT_DIR="${RUNNER_TEMP:-/tmp}/runner-fetch"
PID_FILE="${OUT_DIR}/monitor.pid"
SAMPLES_FILE="${OUT_DIR}/samples.tsv"
SUMMARY_FILE="${OUT_DIR}/summary.json"
PROM_FILE="${OUT_DIR}/metrics.prom"
CHART_FILE="${OUT_DIR}/chart.mermaid"
IO_CHART_FILE="${OUT_DIR}/io_chart.mermaid"
GANTT_FILE="${OUT_DIR}/gantt.mermaid"

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

ENABLE_CPU="${INPUT_MONITOR_CPU:-true}"
ENABLE_MEM="${INPUT_MONITOR_MEMORY:-true}"
ENABLE_DISK="${INPUT_MONITOR_DISK:-false}"
ENABLE_SWAP="${INPUT_MONITOR_SWAP:-false}"
ENABLE_NET="${INPUT_MONITOR_NETWORK:-false}"
ENABLE_DISK_IO="${INPUT_MONITOR_DISK_IO:-false}"
ENABLE_GPU="${INPUT_MONITOR_GPU:-false}"

if [ "$ENABLE_CPU" = "false" ] && [ "$ENABLE_MEM" = "false" ] && [ "$ENABLE_DISK" = "false" ] && [ "$ENABLE_SWAP" = "false" ] && [ "$ENABLE_NET" = "false" ] && [ "$ENABLE_DISK_IO" = "false" ] && [ "$ENABLE_GPU" = "false" ]; then
	exit 0
fi

if [ ! -f "$SAMPLES_FILE" ] || [ "$(wc -l <"$SAMPLES_FILE")" -le 1 ]; then
	echo "Runner telemetry: no samples collected (job completed before sample interval)."
	exit 0
fi

TARGET_OS="${RUNNER_OS:-Linux}"
RUNNER_NAME="${RUNNER_NAME:-unknown}"
PROM_TARGET=""
[ "$INPUT_EXPORT_PROMETHEUS" = "true" ] && PROM_TARGET="$PROM_FILE"

RUNNER_START_EPOCH=""
if [ -n "${RUNNER_TEMP:-}" ] && [ -d "$RUNNER_TEMP" ]; then
	RUNNER_START_EPOCH=$(stat -c %Y "$RUNNER_TEMP" 2>/dev/null || stat -f %m "$RUNNER_TEMP" 2>/dev/null || echo "")
fi

# Truncate output files safely under noclobber (set -C)
: >|"$CHART_FILE"
: >|"$IO_CHART_FILE"
: >|"$GANTT_FILE"
[ -n "$PROM_TARGET" ] && : >|"$PROM_TARGET"

# 2. Single-pass awk processor: Aggregates metrics, formats sparklines, generates Mermaid chart & Prometheus export
STATS=$(awk -F'\t' -v rname="$RUNNER_NAME" -v prom_file="$PROM_TARGET" -v chart_file="$CHART_FILE" -v io_chart_file="$IO_CHART_FILE" -v enable_cpu="$ENABLE_CPU" -v enable_mem="$ENABLE_MEM" -v enable_disk="$ENABLE_DISK" -v enable_swap="$ENABLE_SWAP" -v enable_net="$ENABLE_NET" -v enable_disk_io="$ENABLE_DISK_IO" -v enable_gpu="$ENABLE_GPU" -v runner_start="$RUNNER_START_EPOCH" '
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

# Source of truth for Mermaid 50,000 maxTextSize limit:
# Docs: https://mermaid.js.org/config/setup/mermaid/interfaces/MermaidConfig.html#maxtextsize
# Code Permalink: https://github.com/mermaid-js/mermaid/blob/386bbcaad2ce3ed0cbbba88fab75fb31c5b251e6/packages/mermaid/src/schemas/config.schema.yaml#L87-L90
# Official xyChart documentation: https://mermaid.ai/open-source/syntax/xyChart.html
function get_points_len(candidate_pts,    step_sz, p, s_idx, e_idx, j, max_c, max_m, max_g, max_v, max_sw, c_val, m_val, g_val, v_val, sw_val, total_l) {
	total_l = 0
	step_sz = (count - 1) / (candidate_pts - 1)
	for (p = 0; p < candidate_pts; p++) {
		if (candidate_pts == count) {
			c_val = int(cpu_hist[p + 1])
			m_val = int(mem_hist[p + 1] * 100 / tot_mem)
			g_val = int(gpu_hist[p + 1])
			v_val = (last_vram_tot > 0 ? int(vram_hist[p + 1] * 100 / last_vram_tot) : 0)
			sw_val = (last_sw_tot > 0 ? int(swap_hist[p + 1] * 100 / last_sw_tot) : 0)
		} else {
			s_idx = int(1 + p * step_sz)
			e_idx = int(1 + (p + 1) * step_sz)
			if (e_idx > count) e_idx = count
			max_c = 0; max_m = 0; max_g = 0; max_v = 0; max_sw = 0
			for (j = s_idx; j <= e_idx; j++) {
				if (cpu_hist[j] > max_c) max_c = cpu_hist[j]
				if (mem_hist[j] > max_m) max_m = mem_hist[j]
				if (gpu_hist[j] > max_g) max_g = gpu_hist[j]
				if (vram_hist[j] > max_v) max_v = vram_hist[j]
				if (swap_hist[j] > max_sw) max_sw = swap_hist[j]
			}
			c_val = int(max_c)
			m_val = int(max_m * 100 / tot_mem)
			g_val = int(max_g)
			v_val = (last_vram_tot > 0 ? int(max_v * 100 / last_vram_tot) : 0)
			sw_val = (last_sw_tot > 0 ? int(max_sw * 100 / last_sw_tot) : 0)
		}
		if (c_val < 0) c_val = 0; if (c_val > 100) c_val = 100
		if (m_val < 0) m_val = 0; if (m_val > 100) m_val = 100
		if (g_val < 0) g_val = 0; if (g_val > 100) g_val = 100
		if (v_val < 0) v_val = 0; if (v_val > 100) v_val = 100
		if (sw_val < 0) sw_val = 0; if (sw_val > 100) sw_val = 100

		if (enable_cpu == "true") total_l += length(c_val) + (p > 0 ? 1 : 0)
		if (enable_mem == "true") total_l += length(m_val) + (p > 0 ? 1 : 0)
		if (has_gpu) total_l += length(g_val) + (p > 0 ? 1 : 0)
		if (has_vram) total_l += length(v_val) + (p > 0 ? 1 : 0)
		if (has_swap) total_l += length(sw_val) + (p > 0 ? 1 : 0)
	}
	return total_l
}

function build_mermaid(    job_start, offset_start, offset_end, dur, x_title, x_min, x_max, target_limit, lines_overhead, static_overhead, low, high, mid, p, s_idx, e_idx, j, max_c, max_m, max_g, max_v, max_sw, c_val, m_val, g_val, v_val, sw_val, m_c, m_m, m_g, m_v, m_sw, w, cfg, res, chart_body) {
	has_gpu = (enable_gpu == "true" && (peak_gpu > 0 || last_vram_tot > 0))
	has_vram = (enable_gpu == "true" && last_vram_tot > 0)
	has_swap = (enable_swap == "true" && peak_swap > 0 && last_sw_tot > 0)

	if (enable_cpu != "true" && enable_mem != "true" && !has_gpu && !has_swap) {
		return ""
	}

	if (runner_start != "" && runner_start > 0 && runner_start <= first_epoch) {
		job_start = runner_start
	} else {
		job_start = first_epoch
	}
	offset_start = first_epoch - job_start
	if (offset_start <= 2) offset_start = 0
	offset_end = offset_start + (last_epoch > first_epoch ? (last_epoch - first_epoch) : 1)

	# Dynamic human-readable time scaling for X-axis
	x_title = "Elapsed Time (s)"
	x_min = offset_start
	x_max = offset_end
	if (offset_end >= 86400) {
		x_title = "Elapsed Time (days)"
		x_min = sprintf("%.2f", offset_start / 86400)
		x_max = sprintf("%.2f", offset_end / 86400)
		if (x_min ~ /\.00$/) sub(/\.00$/, "", x_min); else if (x_min ~ /0$/) sub(/0$/, "", x_min)
		if (x_max ~ /\.00$/) sub(/\.00$/, "", x_max); else if (x_max ~ /0$/) sub(/0$/, "", x_max)
	} else if (offset_end >= 3600) {
		x_title = "Elapsed Time (hours)"
		x_min = sprintf("%.2f", offset_start / 3600)
		x_max = sprintf("%.2f", offset_end / 3600)
		if (x_min ~ /\.00$/) sub(/\.00$/, "", x_min); else if (x_min ~ /0$/) sub(/0$/, "", x_min)
		if (x_max ~ /\.00$/) sub(/\.00$/, "", x_max); else if (x_max ~ /0$/) sub(/0$/, "", x_max)
	} else if (offset_end >= 120) {
		x_title = "Elapsed Time (minutes)"
		x_min = sprintf("%.1f", offset_start / 60)
		x_max = sprintf("%.1f", offset_end / 60)
		if (x_min ~ /\.0$/) sub(/\.0$/, "", x_min)
		if (x_max ~ /\.0$/) sub(/\.0$/, "", x_max)
	}

	if (offset_start == 0) x_min = "0"

	if (count < 2) {
		res = "```mermaid\n" \
			"xychart\n" \
			"    title \"Resource Utilization Timeline\"\n" \
			"    x-axis \"" x_title "\" " x_min " --> " x_max "\n" \
			"    y-axis \"Percentage (%)\" 0 --> 100\n"
		if (enable_cpu == "true") res = res "    line \"CPU\" [" int(cpu_hist[1]) "," int(cpu_hist[1]) "]\n"
		if (enable_mem == "true") res = res "    line \"RAM\" [" int(mem_hist[1] * 100 / tot_mem) "," int(mem_hist[1] * 100 / tot_mem) "]\n"
		if (has_gpu) res = res "    line \"GPU\" [" int(gpu_hist[1]) "," int(gpu_hist[1]) "]\n"
		if (has_vram) res = res "    line \"VRAM\" [" (last_vram_tot > 0 ? int(vram_hist[1] * 100 / last_vram_tot) : 0) "," (last_vram_tot > 0 ? int(vram_hist[1] * 100 / last_vram_tot) : 0) "]\n"
		if (has_swap) res = res "    line \"Swap\" [" (last_sw_tot > 0 ? int(swap_hist[1] * 100 / last_sw_tot) : 0) "," (last_sw_tot > 0 ? int(swap_hist[1] * 100 / last_sw_tot) : 0) "]\n"
		res = res "```\n"
		return res
	}

	# Hard ceiling is 50,000 characters (Mermaid defaultConfig maxTextSize).
	# Note: static_overhead includes the markdown fences ("```mermaid\n" and "```\n" = 16 chars),
	# which ensures the inner diagram text evaluated by Mermaid is strictly <= 50,000 chars.
	target_limit = 50000
	lines_overhead = ""
	if (enable_cpu == "true") lines_overhead = lines_overhead "    line \"CPU\" []\n"
	if (enable_mem == "true") lines_overhead = lines_overhead "    line \"RAM\" []\n"
	if (has_gpu) lines_overhead = lines_overhead "    line \"GPU\" []\n"
	if (has_vram) lines_overhead = lines_overhead "    line \"VRAM\" []\n"
	if (has_swap) lines_overhead = lines_overhead "    line \"Swap\" []\n"
	static_overhead = length("```mermaid\n%%{init:{\"xyChart\":{\"width\":}}}%%\nxychart\n    title \"Resource Utilization Timeline\"\n    x-axis \"" x_title "\" " x_min " --> " x_max "\n    y-axis \"Percentage (%)\" 0 --> 100\n" lines_overhead "```\n")

	if (static_overhead + length(count > 700 ? count : 700) + get_points_len(count) <= target_limit) {
		# 100% of all calculated points fit inside the ceiling directly
		pts = count
	} else {
		# Binary search for the exact maximum points that maximizes budget without exceeding ceiling
		low = 2
		high = count
		pts = 2
		while (low <= high) {
			mid = int((low + high) / 2)
			if (static_overhead + length(mid > 700 ? mid : 700) + get_points_len(mid) <= target_limit) {
				pts = mid
				low = mid + 1
			} else {
				high = mid - 1
			}
		}
	}

	# Dynamically scale canvas width smoothly with point density (enforcing >= 1px minimum gap per sample)
	w = (pts > 700 ? pts : 700)
	last_chart_w = w

	cfg = "%%{init:{\"xyChart\":{\"width\":" w "}}}%%\n"

	m_c = "line \"CPU\" ["
	m_m = "line \"RAM\" ["
	m_g = "line \"GPU\" ["
	m_v = "line \"VRAM\" ["
	m_sw = "line \"Swap\" ["

	for (p = 0; p < pts; p++) {
		if (pts == count) {
			# 1:1 exact plotting without downsampling
			c_val = int(cpu_hist[p + 1])
			m_val = int(mem_hist[p + 1] * 100 / tot_mem)
			g_val = int(gpu_hist[p + 1])
			v_val = (last_vram_tot > 0 ? int(vram_hist[p + 1] * 100 / last_vram_tot) : 0)
			sw_val = (last_sw_tot > 0 ? int(swap_hist[p + 1] * 100 / last_sw_tot) : 0)
		} else {
			# Peak-preserving bucket aggregation
			s_idx = int(1 + p * (count - 1) / (pts - 1))
			e_idx = int(1 + (p + 1) * (count - 1) / (pts - 1))
			if (e_idx > count) e_idx = count
			max_c = 0; max_m = 0; max_g = 0; max_v = 0; max_sw = 0
			for (j = s_idx; j <= e_idx; j++) {
				if (cpu_hist[j] > max_c) max_c = cpu_hist[j]
				if (mem_hist[j] > max_m) max_m = mem_hist[j]
				if (gpu_hist[j] > max_g) max_g = gpu_hist[j]
				if (vram_hist[j] > max_v) max_v = vram_hist[j]
				if (swap_hist[j] > max_sw) max_sw = swap_hist[j]
			}
			c_val = int(max_c)
			m_val = int(max_m * 100 / tot_mem)
			g_val = int(max_g)
			v_val = (last_vram_tot > 0 ? int(max_v * 100 / last_vram_tot) : 0)
			sw_val = (last_sw_tot > 0 ? int(max_sw * 100 / last_sw_tot) : 0)
		}

		if (c_val < 0) c_val = 0; if (c_val > 100) c_val = 100
		if (m_val < 0) m_val = 0; if (m_val > 100) m_val = 100
		if (g_val < 0) g_val = 0; if (g_val > 100) g_val = 100
		if (v_val < 0) v_val = 0; if (v_val > 100) v_val = 100
		if (sw_val < 0) sw_val = 0; if (sw_val > 100) sw_val = 100

		if (enable_cpu == "true") {
			if (p == 0) m_c = m_c c_val; else m_c = m_c "," c_val
		}
		if (enable_mem == "true") {
			if (p == 0) m_m = m_m m_val; else m_m = m_m "," m_val
		}
		if (has_gpu) {
			if (p == 0) m_g = m_g g_val; else m_g = m_g "," g_val
		}
		if (has_vram) {
			if (p == 0) m_v = m_v v_val; else m_v = m_v "," v_val
		}
		if (has_swap) {
			if (p == 0) m_sw = m_sw sw_val; else m_sw = m_sw "," sw_val
		}
	}
	m_c = m_c "]"
	m_m = m_m "]"
	m_g = m_g "]"
	m_v = m_v "]"
	m_sw = m_sw "]"

	chart_body = "```mermaid\n" cfg \
		"xychart\n" \
		"    title \"Resource Utilization Timeline\"\n" \
		"    x-axis \"" x_title "\" " x_min " --> " x_max "\n" \
		"    y-axis \"Percentage (%)\" 0 --> 100\n"
	if (enable_cpu == "true") chart_body = chart_body "    " m_c "\n"
	if (enable_mem == "true") chart_body = chart_body "    " m_m "\n"
	if (has_gpu) chart_body = chart_body "    " m_g "\n"
	if (has_vram) chart_body = chart_body "    " m_v "\n"
	if (has_swap) chart_body = chart_body "    " m_sw "\n"
	chart_body = chart_body "```\n"

	return chart_body
}

function get_io_points_len(candidate_pts,    step_sz, p, s_idx, e_idx, j, max_dr, max_dw, max_rx, max_tx, dr_val, dw_val, rx_val, tx_val, total_l) {
	total_l = 0
	step_sz = (count - 1) / (candidate_pts - 1)
	for (p = 0; p < candidate_pts; p++) {
		if (candidate_pts == count) {
			dr_val = int(dr_hist[p + 1])
			dw_val = int(dw_hist[p + 1])
			rx_val = int(rx_hist[p + 1])
			tx_val = int(tx_hist[p + 1])
		} else {
			s_idx = int(1 + p * step_sz)
			e_idx = int(1 + (p + 1) * step_sz)
			if (e_idx > count) e_idx = count
			max_dr = 0; max_dw = 0; max_rx = 0; max_tx = 0
			for (j = s_idx; j <= e_idx; j++) {
				if (dr_hist[j] > max_dr) max_dr = dr_hist[j]
				if (dw_hist[j] > max_dw) max_dw = dw_hist[j]
				if (rx_hist[j] > max_rx) max_rx = rx_hist[j]
				if (tx_hist[j] > max_tx) max_tx = tx_hist[j]
			}
			dr_val = int(max_dr)
			dw_val = int(max_dw)
			rx_val = int(max_rx)
			tx_val = int(max_tx)
		}
		if (dr_val < 0) dr_val = 0
		if (dw_val < 0) dw_val = 0
		if (rx_val < 0) rx_val = 0
		if (tx_val < 0) tx_val = 0

		if (enable_disk_io == "true") {
			total_l += length(dr_val) + length(dw_val) + (p > 0 ? 2 : 0)
		}
		if (enable_net == "true") {
			total_l += length(rx_val) + length(tx_val) + (p > 0 ? 2 : 0)
		}
	}
	return total_l
}

function build_io_mermaid(    job_start, offset_start, offset_end, x_title, x_min, x_max, cfg, p, s_idx, e_idx, j, max_dr, max_dw, max_rx, max_tx, dr_val, dw_val, rx_val, tx_val, peak_val, y_max, m_dr, m_dw, m_rx, m_tx, chart_body, res, pts_io, target_limit, lines_overhead, static_overhead, low, high, mid, w) {
	if (enable_net != "true" && enable_disk_io != "true") {
		return ""
	}

	if (runner_start != "" && runner_start > 0 && runner_start <= first_epoch) {
		job_start = runner_start
	} else {
		job_start = first_epoch
	}
	offset_start = first_epoch - job_start
	if (offset_start <= 2) offset_start = 0
	offset_end = offset_start + (last_epoch > first_epoch ? (last_epoch - first_epoch) : 1)

	x_title = "Elapsed Time (s)"
	x_min = offset_start
	x_max = offset_end
	if (offset_end >= 86400) {
		x_title = "Elapsed Time (days)"
		x_min = sprintf("%.2f", offset_start / 86400)
		x_max = sprintf("%.2f", offset_end / 86400)
		if (x_min ~ /\.00$/) sub(/\.00$/, "", x_min); else if (x_min ~ /0$/) sub(/0$/, "", x_min)
		if (x_max ~ /\.00$/) sub(/\.00$/, "", x_max); else if (x_max ~ /0$/) sub(/0$/, "", x_max)
	} else if (offset_end >= 3600) {
		x_title = "Elapsed Time (hours)"
		x_min = sprintf("%.2f", offset_start / 3600)
		x_max = sprintf("%.2f", offset_end / 3600)
		if (x_min ~ /\.00$/) sub(/\.00$/, "", x_min); else if (x_min ~ /0$/) sub(/0$/, "", x_min)
		if (x_max ~ /\.00$/) sub(/\.00$/, "", x_max); else if (x_max ~ /0$/) sub(/0$/, "", x_max)
	} else if (offset_end >= 120) {
		x_title = "Elapsed Time (minutes)"
		x_min = sprintf("%.1f", offset_start / 60)
		x_max = sprintf("%.1f", offset_end / 60)
		if (x_min ~ /\.0$/) sub(/\.0$/, "", x_min)
		if (x_max ~ /\.0$/) sub(/\.0$/, "", x_max)
	}
	if (offset_start == 0) x_min = "0"

	if (count < 2) {
		peak_val = 0
		if (enable_disk_io == "true") {
			if (dr_hist[1] > peak_val) peak_val = dr_hist[1]
			if (dw_hist[1] > peak_val) peak_val = dw_hist[1]
		}
		if (enable_net == "true") {
			if (rx_hist[1] > peak_val) peak_val = rx_hist[1]
			if (tx_hist[1] > peak_val) peak_val = tx_hist[1]
		}
		y_max = (peak_val > 0 ? int(peak_val * 1.1) + 1 : 10)
		res = "```mermaid\n" \
			"xychart\n" \
			"    title \"I/O Throughput Timeline\"\n" \
			"    x-axis \"" x_title "\" " x_min " --> " x_max "\n" \
			"    y-axis \"Throughput (MB)\" 0 --> " y_max "\n"
		if (enable_disk_io == "true") {
			res = res "    line \"Disk Read\" [" int(dr_hist[1]) "," int(dr_hist[1]) "]\n"
			res = res "    line \"Disk Write\" [" int(dw_hist[1]) "," int(dw_hist[1]) "]\n"
		}
		if (enable_net == "true") {
			res = res "    line \"Net RX\" [" int(rx_hist[1]) "," int(rx_hist[1]) "]\n"
			res = res "    line \"Net TX\" [" int(tx_hist[1]) "," int(tx_hist[1]) "]\n"
		}
		res = res "```\n"
		return res
	}

	target_limit = 50000
	lines_overhead = ""
	if (enable_disk_io == "true") lines_overhead = lines_overhead "    line \"Disk Read\" []\n    line \"Disk Write\" []\n"
	if (enable_net == "true") lines_overhead = lines_overhead "    line \"Net RX\" []\n    line \"Net TX\" []\n"
	static_overhead = length("```mermaid\n%%{init:{\"xyChart\":{\"width\":}}}%%\nxychart\n    title \"I/O Throughput Timeline\"\n    x-axis \"" x_title "\" " x_min " --> " x_max "\n    y-axis \"Throughput (MB)\" 0 --> 999999\n" lines_overhead "```\n")

	if (pts > 0 && static_overhead + length(pts > 700 ? pts : 700) + get_io_points_len(pts) <= target_limit) {
		pts_io = pts
	} else if (static_overhead + length(count > 700 ? count : 700) + get_io_points_len(count) <= target_limit) {
		pts_io = count
	} else {
		low = 2
		high = (pts > 0 ? pts : count)
		pts_io = 2
		while (low <= high) {
			mid = int((low + high) / 2)
			if (static_overhead + length(mid > 700 ? mid : 700) + get_io_points_len(mid) <= target_limit) {
				pts_io = mid
				low = mid + 1
			} else {
				high = mid - 1
			}
		}
	}

	if (last_chart_w > 0) w = last_chart_w
	else {
		w = (pts_io > 700 ? pts_io : 700)
		last_chart_w = w
	}

	cfg = "%%{init:{\"xyChart\":{\"width\":" w "}}}%%\n"

	m_dr = "line \"Disk Read\" ["
	m_dw = "line \"Disk Write\" ["
	m_rx = "line \"Net RX\" ["
	m_tx = "line \"Net TX\" ["

	peak_val = 0
	for (p = 0; p < pts_io; p++) {
		if (pts_io == count) {
			dr_val = int(dr_hist[p + 1])
			dw_val = int(dw_hist[p + 1])
			rx_val = int(rx_hist[p + 1])
			tx_val = int(tx_hist[p + 1])
		} else {
			s_idx = int(1 + p * (count - 1) / (pts_io - 1))
			e_idx = int(1 + (p + 1) * (count - 1) / (pts_io - 1))
			if (e_idx > count) e_idx = count
			max_dr = 0; max_dw = 0; max_rx = 0; max_tx = 0
			for (j = s_idx; j <= e_idx; j++) {
				if (dr_hist[j] > max_dr) max_dr = dr_hist[j]
				if (dw_hist[j] > max_dw) max_dw = dw_hist[j]
				if (rx_hist[j] > max_rx) max_rx = rx_hist[j]
				if (tx_hist[j] > max_tx) max_tx = tx_hist[j]
			}
			dr_val = int(max_dr)
			dw_val = int(max_dw)
			rx_val = int(max_rx)
			tx_val = int(max_tx)
		}

		if (dr_val < 0) dr_val = 0
		if (dw_val < 0) dw_val = 0
		if (rx_val < 0) rx_val = 0
		if (tx_val < 0) tx_val = 0

		if (enable_disk_io == "true") {
			if (dr_val > peak_val) peak_val = dr_val
			if (dw_val > peak_val) peak_val = dw_val
			if (p == 0) {
				m_dr = m_dr dr_val
				m_dw = m_dw dw_val
			} else {
				m_dr = m_dr "," dr_val
				m_dw = m_dw "," dw_val
			}
		}
		if (enable_net == "true") {
			if (rx_val > peak_val) peak_val = rx_val
			if (tx_val > peak_val) peak_val = tx_val
			if (p == 0) {
				m_rx = m_rx rx_val
				m_tx = m_tx tx_val
			} else {
				m_rx = m_rx "," rx_val
				m_tx = m_tx "," tx_val
			}
		}
	}

	m_dr = m_dr "]"
	m_dw = m_dw "]"
	m_rx = m_rx "]"
	m_tx = m_tx "]"

	y_max = (peak_val > 0 ? int(peak_val * 1.1) + 1 : 10)

	chart_body = "```mermaid\n" cfg \
		"xychart\n" \
		"    title \"I/O Throughput Timeline\"\n" \
		"    x-axis \"" x_title "\" " x_min " --> " x_max "\n" \
		"    y-axis \"Throughput (MB)\" 0 --> " y_max "\n"
	if (enable_disk_io == "true") {
		chart_body = chart_body "    " m_dr "\n"
		chart_body = chart_body "    " m_dw "\n"
	}
	if (enable_net == "true") {
		chart_body = chart_body "    " m_rx "\n"
		chart_body = chart_body "    " m_tx "\n"
	}
	chart_body = chart_body "```\n"

	return chart_body
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
		if (enable_cpu == "true") {
			print "# HELP runner_cpu_percent Total CPU usage percentage" > prom_file
			print "# TYPE runner_cpu_percent gauge" >> prom_file
			print "# HELP runner_cpu_user_percent User space CPU percentage" >> prom_file
			print "# TYPE runner_cpu_user_percent gauge" >> prom_file
			print "# HELP runner_cpu_system_percent Kernel space CPU percentage" >> prom_file
			print "# TYPE runner_cpu_system_percent gauge" >> prom_file
			print "# HELP runner_cpu_steal_percent Hypervisor steal CPU percentage" >> prom_file
			print "# TYPE runner_cpu_steal_percent gauge" >> prom_file
		}
		if (enable_mem == "true") {
			print "# HELP runner_memory_used_bytes Memory used in bytes" >> prom_file
			print "# TYPE runner_memory_used_bytes gauge" >> prom_file
			print "# HELP runner_memory_available_bytes Memory available in bytes" >> prom_file
			print "# TYPE runner_memory_available_bytes gauge" >> prom_file
		}
		if (enable_disk == "true") {
			print "# HELP runner_disk_free_bytes Free disk space in bytes" >> prom_file
			print "# TYPE runner_disk_free_bytes gauge" >> prom_file
		}
		if (enable_swap == "true") {
			print "# HELP runner_swap_used_bytes Swap space used in bytes" >> prom_file
			print "# TYPE runner_swap_used_bytes gauge" >> prom_file
			print "# HELP runner_swap_total_bytes Total swap space in bytes" >> prom_file
			print "# TYPE runner_swap_total_bytes gauge" >> prom_file
		}
		if (enable_net == "true") {
			print "# HELP runner_network_receive_bytes Total network bytes received" >> prom_file
			print "# TYPE runner_network_receive_bytes gauge" >> prom_file
			print "# HELP runner_network_transmit_bytes Total network bytes transmitted" >> prom_file
			print "# TYPE runner_network_transmit_bytes gauge" >> prom_file
		}
		if (enable_disk_io == "true") {
			print "# HELP runner_disk_read_bytes Total disk bytes read" >> prom_file
			print "# TYPE runner_disk_read_bytes gauge" >> prom_file
			print "# HELP runner_disk_written_bytes Total disk bytes written" >> prom_file
			print "# TYPE runner_disk_written_bytes gauge" >> prom_file
		}
		if (enable_gpu == "true") {
			print "# HELP runner_gpu_utilization_percent GPU core utilization percentage" >> prom_file
			print "# TYPE runner_gpu_utilization_percent gauge" >> prom_file
			print "# HELP runner_gpu_vram_used_bytes GPU VRAM used in bytes" >> prom_file
			print "# TYPE runner_gpu_vram_used_bytes gauge" >> prom_file
			print "# HELP runner_gpu_vram_total_bytes GPU total VRAM in bytes" >> prom_file
			print "# TYPE runner_gpu_vram_total_bytes gauge" >> prom_file
		}
	}
}

NR > 1 {
	count++
	epoch = $1
	u = $2; s = $3; st = $4; io = $5; tot = $6
	m_used = $7; m_avail = $8; d_free = $9; oom = $10
	sw_used = ($11 != "" ? $11 : 0)
	sw_tot = ($12 != "" ? $12 : 0)
	rx_mb = ($13 != "" ? $13 : 0)
	tx_mb = ($14 != "" ? $14 : 0)
	dr_mb = ($15 != "" ? $15 : 0)
	dw_mb = ($16 != "" ? $16 : 0)
	gpu_u = ($17 != "" ? $17 : 0)
	vram_u = ($18 != "" ? $18 : 0)
	vram_t = ($19 != "" ? $19 : 0)

	if (count == 1) {
		first_epoch = epoch
		m_init = m_used
		d_init = d_free
		sw_init = sw_used
		net_rx_init = rx_mb
		net_tx_init = tx_mb
		disk_r_init = dr_mb
		disk_w_init = dw_mb
		peak_mem = m_used
		peak_cpu = tot
		peak_swap = sw_used
		peak_gpu = gpu_u
		peak_vram = vram_u
		max_steal = st
	}

	cpu_sum += tot
	if (tot > peak_cpu) peak_cpu = tot
	if (st > max_steal) max_steal = st
	if (m_used > peak_mem) peak_mem = m_used
	if (sw_used > peak_swap) peak_swap = sw_used
	if (oom > 0) oom_count += oom

	gpu_sum += gpu_u
	if (gpu_u > peak_gpu) peak_gpu = gpu_u
	if (vram_u > peak_vram) peak_vram = vram_u
	last_vram_tot = vram_t

	last_epoch = epoch
	m_final = m_used
	d_final = d_free
	last_avail = m_avail
	sw_final = sw_used
	last_sw_tot = sw_tot
	net_rx_final = rx_mb
	net_tx_final = tx_mb
	disk_r_final = dr_mb
	disk_w_final = dw_mb

	d_rx = (count > 1 ? rx_mb - prev_rx : 0)
	d_tx = (count > 1 ? tx_mb - prev_tx : 0)
	if (d_rx < 0) d_rx = 0
	if (d_tx < 0) d_tx = 0
	d_net = d_rx + d_tx
	if (d_net > peak_delta_net) peak_delta_net = d_net
	net_hist[count] = d_net
	rx_hist[count] = d_rx
	tx_hist[count] = d_tx

	prev_rx = rx_mb
	prev_tx = tx_mb

	d_dr = (count > 1 ? dr_mb - prev_dr : 0)
	d_dw = (count > 1 ? dw_mb - prev_dw : 0)
	if (d_dr < 0) d_dr = 0
	if (d_dw < 0) d_dw = 0
	d_dio = d_dr + d_dw
	if (d_dio > peak_delta_dio) peak_delta_dio = d_dio
	dio_hist[count] = d_dio
	dr_hist[count] = d_dr
	dw_hist[count] = d_dw

	prev_dr = dr_mb
	prev_dw = dw_mb

	t_hist[count] = epoch
	cpu_hist[count] = tot
	mem_hist[count] = m_used
	swap_hist[count] = sw_used
	gpu_hist[count] = gpu_u
	vram_hist[count] = vram_u

	if (prom_file != "") {
		ts = epoch "000"
		if (enable_cpu == "true") {
			printf "runner_cpu_percent{runner=\"%s\"} %s %s\n", rname, tot, ts >> prom_file
			printf "runner_cpu_user_percent{runner=\"%s\"} %s %s\n", rname, u, ts >> prom_file
			printf "runner_cpu_system_percent{runner=\"%s\"} %s %s\n", rname, s, ts >> prom_file
			printf "runner_cpu_steal_percent{runner=\"%s\"} %s %s\n", rname, st, ts >> prom_file
		}
		if (enable_mem == "true") {
			printf "runner_memory_used_bytes{runner=\"%s\"} %d %s\n", rname, (m_used * 1048576), ts >> prom_file
			printf "runner_memory_available_bytes{runner=\"%s\"} %d %s\n", rname, (m_avail * 1048576), ts >> prom_file
		}
		if (enable_disk == "true") {
			printf "runner_disk_free_bytes{runner=\"%s\",mount=\"/\"} %d %s\n", rname, (d_free * 1048576), ts >> prom_file
		}
		if (enable_swap == "true") {
			printf "runner_swap_used_bytes{runner=\"%s\"} %d %s\n", rname, (sw_used * 1048576), ts >> prom_file
			printf "runner_swap_total_bytes{runner=\"%s\"} %d %s\n", rname, (sw_tot * 1048576), ts >> prom_file
		}
		if (enable_net == "true") {
			printf "runner_network_receive_bytes{runner=\"%s\"} %d %s\n", rname, (rx_mb * 1048576), ts >> prom_file
			printf "runner_network_transmit_bytes{runner=\"%s\"} %d %s\n", rname, (tx_mb * 1048576), ts >> prom_file
		}
		if (enable_disk_io == "true") {
			printf "runner_disk_read_bytes{runner=\"%s\"} %d %s\n", rname, (dr_mb * 1048576), ts >> prom_file
			printf "runner_disk_written_bytes{runner=\"%s\"} %d %s\n", rname, (dw_mb * 1048576), ts >> prom_file
		}
		if (enable_gpu == "true") {
			printf "runner_gpu_utilization_percent{runner=\"%s\"} %s %s\n", rname, gpu_u, ts >> prom_file
			printf "runner_gpu_vram_used_bytes{runner=\"%s\"} %d %s\n", rname, (vram_u * 1048576), ts >> prom_file
			printf "runner_gpu_vram_total_bytes{runner=\"%s\"} %d %s\n", rname, (vram_t * 1048576), ts >> prom_file
		}
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
	sw_max_limit = (last_sw_tot > 0 ? last_sw_tot : (peak_swap > 0 ? peak_swap : 100))
	tot_rx = (net_rx_final >= net_rx_init ? net_rx_final - net_rx_init : net_rx_final)
	tot_tx = (net_tx_final >= net_tx_init ? net_tx_final - net_tx_init : net_tx_final)
	net_spark = get_spark(net_hist, count, (peak_delta_net > 0 ? peak_delta_net : 100))
	tot_dr = (disk_r_final >= disk_r_init ? disk_r_final - disk_r_init : disk_r_final)
	tot_dw = (disk_w_final >= disk_w_init ? disk_w_final - disk_w_init : disk_w_final)
	dio_spark = get_spark(dio_hist, count, (peak_delta_dio > 0 ? peak_delta_dio : 100))
	avg_gpu = int(gpu_sum / count)
	vram_max_limit = (last_vram_tot > 0 ? last_vram_tot : (peak_vram > 0 ? peak_vram : 100))
	gpu_spark = get_spark(gpu_hist, count, 100)
	vram_spark = get_spark(vram_hist, count, vram_max_limit)

	if (runner_start != "" && runner_start > 0 && runner_start <= first_epoch) {
		job_start = runner_start
	} else {
		job_start = first_epoch
	}
	offset_start = first_epoch - job_start
	if (offset_start <= 2) offset_start = 0

	if (chart_file != "") {
		chart_content = build_mermaid()
		if (chart_content != "") {
			printf "%s", chart_content > chart_file
		}
	}
	if (io_chart_file != "") {
		io_chart_content = build_io_mermaid()
		if (io_chart_content != "") {
			printf "%s", io_chart_content > io_chart_file
		}
	}

	printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%s\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%s\t%s\t%d\t%d\n",
		count, duration, avg_cpu, peak_cpu, max_steal,
		m_init, peak_mem, m_final, tot_mem, peak_mem_pct,
		d_consumed, oom_count,
		get_spark(cpu_hist, count, 100),
		get_spark(mem_hist, count, tot_mem),
		offset_start,
		sw_init, peak_swap, sw_final, last_sw_tot,
		get_spark(swap_hist, count, sw_max_limit),
		tot_rx, tot_tx, net_spark,
		tot_dr, tot_dw, dio_spark,
		avg_gpu, peak_gpu, peak_vram, last_vram_tot,
		gpu_spark, vram_spark,
		(last_chart_w > 0 ? last_chart_w : (count > 700 ? count : 700)),
		job_start
}' "$SAMPLES_FILE")

IFS='	' read -r SAMPLE_COUNT DURATION_SEC CPU_AVG CPU_PEAK CPU_STEAL_MAX \
	MEM_INIT_MB MEM_PEAK_MB MEM_FINAL_MB MEM_TOTAL_MB MEM_PEAK_PCT \
	DISK_CONSUMED_MB OOM_COUNT CPU_SPARKLINE MEM_SPARKLINE JOB_OFFSET_SEC \
	SWAP_INIT_MB SWAP_PEAK_MB SWAP_FINAL_MB SWAP_TOTAL_MB SWAP_SPARKLINE \
	NET_RX_MB NET_TX_MB NET_SPARKLINE \
	DISK_READ_MB DISK_WRITE_MB DISK_IO_SPARKLINE \
	GPU_AVG GPU_PEAK VRAM_PEAK_MB VRAM_TOTAL_MB GPU_SPARKLINE VRAM_SPARKLINE \
	CHART_WIDTH JOB_START_EPOCH <<EOF
$STATS
EOF

CHART_WIDTH="${CHART_WIDTH:-1000}"
JOB_START_EPOCH="${JOB_START_EPOCH:-0}"
OFFSET_START="${JOB_OFFSET_SEC:-0}"
OFFSET_END="$((${JOB_OFFSET_SEC:-0} + ${DURATION_SEC:-0}))"

SWAP_INIT_MB="${SWAP_INIT_MB:-0}"
SWAP_PEAK_MB="${SWAP_PEAK_MB:-0}"
SWAP_FINAL_MB="${SWAP_FINAL_MB:-0}"
SWAP_TOTAL_MB="${SWAP_TOTAL_MB:-0}"
SWAP_SPARKLINE="${SWAP_SPARKLINE:-—}"
NET_RX_MB="${NET_RX_MB:-0}"
NET_TX_MB="${NET_TX_MB:-0}"
NET_SPARKLINE="${NET_SPARKLINE:-—}"
DISK_READ_MB="${DISK_READ_MB:-0}"
DISK_WRITE_MB="${DISK_WRITE_MB:-0}"
DISK_IO_SPARKLINE="${DISK_IO_SPARKLINE:-—}"
GPU_AVG="${GPU_AVG:-0}"
GPU_PEAK="${GPU_PEAK:-0}"
VRAM_PEAK_MB="${VRAM_PEAK_MB:-0}"
VRAM_TOTAL_MB="${VRAM_TOTAL_MB:-0}"
GPU_SPARKLINE="${GPU_SPARKLINE:-—}"
VRAM_SPARKLINE="${VRAM_SPARKLINE:-—}"

# 3. Storage Baseline & Pre-installed Bloat Extraction
STORAGE_BASELINE_FILE="${OUT_DIR}/storage_baseline.tsv"
ROOT_TOTAL_BYTES=0
ROOT_USED_BYTES=0
ROOT_FREE_BYTES=0

if [ -f "$STORAGE_BASELINE_FILE" ]; then
	IFS='	' read -r ROOT_TOTAL_BYTES ROOT_USED_BYTES ROOT_FREE_BYTES <"$STORAGE_BASELINE_FILE" || true
fi

if [ -z "$ROOT_TOTAL_BYTES" ] || [ "$ROOT_TOTAL_BYTES" -le 0 ]; then
	if command -v df >/dev/null 2>&1; then
		DF_TARGET="/"
		[ "$TARGET_OS" = "Windows" ] && DF_TARGET="/c"
		STATS_DF=$(df -k -P "$DF_TARGET" 2>/dev/null | awk 'NR == 2 { printf "%s\t%s\t%s\n", $2 * 1024, $3 * 1024, $4 * 1024 }' || echo "")
		if [ -n "$STATS_DF" ]; then
			IFS='	' read -r ROOT_TOTAL_BYTES ROOT_USED_BYTES ROOT_FREE_BYTES <<EOF
$STATS_DF
EOF
		fi
	fi
fi

ROOT_TOTAL_GB="0"
ROOT_USED_GB="0"
ROOT_FREE_GB="0"
ROOT_USED_PCT=0

if [ -n "$ROOT_TOTAL_BYTES" ] && [ "$ROOT_TOTAL_BYTES" -gt 0 ]; then
	STORAGE_FORMAT=$(awk -v tot="$ROOT_TOTAL_BYTES" -v used="$ROOT_USED_BYTES" -v free="$ROOT_FREE_BYTES" 'BEGIN {
		tot_gb = sprintf("%.1f", tot / 1073741824)
		used_gb = sprintf("%.1f", used / 1073741824)
		free_gb = sprintf("%.1f", free / 1073741824)
		used_pct = int((used * 100) / tot)
		printf "%s\t%s\t%s\t%d\n", tot_gb, used_gb, free_gb, used_pct
	}')
	IFS='	' read -r ROOT_TOTAL_GB ROOT_USED_GB ROOT_FREE_GB ROOT_USED_PCT <<EOF
$STORAGE_FORMAT
EOF
fi

STORAGE_BASELINE_JSON=$(printf '{"total_bytes":%s,"used_bytes":%s,"free_bytes":%s,"preinstalled_bloat_percent":%d}' \
	"${ROOT_TOTAL_BYTES:-0}" "${ROOT_USED_BYTES:-0}" "${ROOT_FREE_BYTES:-0}" "${ROOT_USED_PCT:-0}")

# 4. Phase & Milestone Extraction & Companion Gantt Chart
PHASES_FILE="${OUT_DIR}/phases.tsv"
PHASES_JSON="[]"
MILESTONES_JSON="[]"
PHASE_TABLE_ROWS=""

if [ -f "$PHASES_FILE" ]; then
	PHASE_TABLE_ROWS=$(awk -F'\t' -v job_start="${JOB_START_EPOCH:-0}" '
	$1 == "SUMMARY" {
		name = $2; dur = $3; mem = $4; cpu = $5; disk = $6
		dur_str = dur "s"
		if (dur >= 60) {
			m = int(dur / 60)
			s = dur % 60
			dur_str = sprintf("%dm %02ds (%ds)", m, s, dur)
		}
		printf "| **%s** | %s | %d MB | %d%% | %d MB |\n", name, dur_str, mem, cpu, disk
	}
	$1 == "MILESTONE" {
		name = $2; epoch = $3; mem = $4; cpu = $5; disk = $6
		off = (job_start > 0 ? epoch - job_start : 0)
		if (off < 0) off = 0
		off_str = sprintf("+%ds", off)
		if (off >= 60) {
			m = int(off / 60)
			s = off % 60
			off_str = sprintf("+%dm %02ds", m, s)
		}
		disk_str = (disk > 0 ? sprintf("%d MB free", disk) : "—")
		printf "| 📍 **%s** | *Milestone* (%s) | %d MB | %d%% | %s |\n", name, off_str, mem, cpu, disk_str
	}' "$PHASES_FILE")

	PHASES_JSON=$(awk -F'\t' '
	BEGIN { printf "[" }
	$1 == "SUMMARY" {
		if (count > 0) printf ","
		gsub(/"/, "\\\"", $2)
		printf "{\"name\":\"%s\",\"duration_seconds\":%d,\"peak_memory_mb\":%d,\"avg_cpu_percent\":%d,\"disk_consumed_mb\":%d}", $2, $3, $4, $5, $6
		count++
	}
	END { printf "]" }
	' "$PHASES_FILE")

	MILESTONES_JSON=$(awk -F'\t' -v job_start="${JOB_START_EPOCH:-0}" '
	BEGIN { printf "[" }
	$1 == "MILESTONE" {
		if (count > 0) printf ","
		gsub(/"/, "\\\"", $2)
		off = (job_start > 0 ? $3 - job_start : 0)
		if (off < 0) off = 0
		printf "{\"name\":\"%s\",\"timestamp\":%d,\"offset_seconds\":%d,\"memory_mb\":%d,\"cpu_percent\":%d,\"disk_free_mb\":%d}", $2, $3, off, $4, $5, $6
		count++
	}
	END { printf "]" }
	' "$PHASES_FILE")

	GANTT_CONTENT=$(awk -F'\t' -v w="${CHART_WIDTH:-1000}" -v job_start="${JOB_START_EPOCH:-0}" -v off_start="${OFFSET_START:-0}" -v off_end="${OFFSET_END:-0}" '
	function fmt_time(sec,   d, rem, h, m, s) {
		if (sec < 0) sec = 0
		d = 1 + int(sec / 86400)
		rem = sec % 86400
		h = int(rem / 3600)
		rem = rem % 3600
		m = int(rem / 60)
		s = rem % 60
		return sprintf("2000-01-%02d %02d:%02d:%02d", d, h, m, s)
	}
	BEGIN {
		has_items = 0
		phase_count = 0
		milestone_count = 0
	}
	$1 == "START" {
		start_times[$3] = $2
	}
	$1 == "SUMMARY" {
		name = $2
		s = (NF >= 7 && $7 > 0) ? $7 : (start_times[name] > 0 ? start_times[name] : 0)
		e = (NF >= 8 && $8 > 0) ? $8 : (s + $3)
		if (job_start > 0) {
			s = s - job_start
			e = e - job_start
		}
		if (s < 0) s = 0
		if (e <= s) e = s + 1
		gsub(/:/, "-", name)
		phase_count++
		phases[phase_count] = sprintf("    %s : active, %s, %s\n", name, fmt_time(s), fmt_time(e))
		has_items = 1
	}
	$1 == "MILESTONE" {
		name = $2
		t = $3
		if (job_start > 0) {
			t = t - job_start
		}
		if (t < 0) t = 0
		gsub(/:/, "-", name)
		milestone_count++
		milestones[milestone_count] = sprintf("    %s : milestone, %s, %s\n", name, fmt_time(t), fmt_time(t))
		has_items = 1
	}
	END {
		if (has_items == 1) {
			if (off_end >= 86400) {
				axis_fmt = "Day %d"
			} else if (off_end >= 3600) {
				axis_fmt = "%H:%M:%S"
			} else {
				axis_fmt = "%M:%S"
			}
			anchor_s = fmt_time(off_start)
			anchor_e = fmt_time((off_end > off_start ? off_end : off_start + 1))

			printf "```mermaid\n"
			printf "%%%%{init:{\"gantt\":{\"useWidth\":%d,\"useMaxWidth\":false}}}%%%%\n", (w > 0 ? w : 1000)
			printf "gantt\n"
			printf "    title Workflow Phases & Milestones\n"
			printf "    dateFormat YYYY-MM-DD HH:mm:ss\n"
			printf "    axisFormat %s\n", axis_fmt
			printf "    section Overall\n"
			printf "    Job Telemetry : done, %s, %s\n", anchor_s, anchor_e
			if (phase_count > 0) {
				printf "    section Phases\n"
				for (i = 1; i <= phase_count; i++) printf "%s", phases[i]
			}
			if (milestone_count > 0) {
				printf "    section Milestones\n"
				for (i = 1; i <= milestone_count; i++) printf "%s", milestones[i]
			}
			printf "```\n"
		}
	}' "$PHASES_FILE")

	if [ -n "$GANTT_CONTENT" ]; then
		echo "$GANTT_CONTENT" >|"$GANTT_FILE"
	fi
fi

# 5. Kernel OOM Check
OOM_DETECTED="false"
OOM_DETAILS=""

if [ "$ENABLE_MEM" = "true" ]; then
	if [ "$OOM_COUNT" -gt 0 ]; then
		OOM_DETECTED="true"
		OOM_DETAILS="Kernel recorded ${OOM_COUNT} process kill event(s)."
	fi

	if [ "$OOM_DETECTED" = "false" ]; then
		case "$TARGET_OS" in
		"Linux")
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
			;;

		"macOS")
			MINS=$(((${DURATION_SEC:-0} / 60) + 2))
			MAC_OOM_REPORT=$(find /Library/Logs/DiagnosticReports ~/Library/Logs/DiagnosticReports -type f -name "JetsamEvent*.ips" -mmin -"$MINS" 2>/dev/null | head -n 1 || true)
			if [ -z "$MAC_OOM_REPORT" ]; then
				MAC_OOM_REPORT=$(find /Library/Logs/DiagnosticReports ~/Library/Logs/DiagnosticReports -type f -name "*.ips" -mmin -"$MINS" -exec grep -l "RESOURCE_TYPE_MEMORY" {} + 2>/dev/null | head -n 1 || true)
			fi
			if [ -n "$MAC_OOM_REPORT" ]; then
				OOM_DETECTED="true"
				OOM_DETAILS="macOS kernel Jetsam/memorystatus terminated process due to memory exhaustion ($(basename "$MAC_OOM_REPORT"))."
			fi
			;;

		"Windows")
			if command -v wevtutil.exe >/dev/null 2>&1 || command -v wevtutil >/dev/null 2>&1; then
				WIN_OOM_MS=$(((${DURATION_SEC:-0} + 60) * 1000))
				WIN_OOM=$(wevtutil qe System /q:"*[System[EventID=2004 and TimeCreated[timediff(@SystemTime) <= ${WIN_OOM_MS}]]]" /c:1 /rd:true /f:text 2>/dev/null || true)
				if [ -n "$WIN_OOM" ]; then
					OOM_DETECTED="true"
					OOM_DETAILS=$(printf '%s' "$WIN_OOM" | grep -iE 'Windows successfully diagnosed|consumed the most virtual memory' | head -n 1 | tr '\r\n' '  ' || echo "")
					[ -z "$OOM_DETAILS" ] && OOM_DETAILS="Windows Resource-Exhaustion-Detector confirmed low virtual memory condition (Event 2004)."
				fi
			fi
			;;
		esac
	fi
fi

# 6. Generate summary.json (Single Source of Truth)
ESCAPED_OOM_DETAILS=$(printf '%s' "$OOM_DETAILS" | tr '\r\n\t' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
SUMMARY_JSON=$(printf '{"duration_seconds":%d,"job_offset_seconds":%d,"samples_count":%d,"cpu":{"average_percent":%d,"peak_percent":%d,"max_steal_percent":%d},"memory":{"initial_mb":%d,"peak_mb":%d,"final_mb":%d,"total_mb":%d,"peak_percent":%d},"swap":{"initial_mb":%d,"peak_mb":%d,"final_mb":%d,"total_mb":%d},"network":{"rx_mb":%d,"tx_mb":%d},"disk_io":{"read_mb":%d,"write_mb":%d},"gpu":{"average_percent":%d,"peak_percent":%d,"peak_vram_mb":%d,"total_vram_mb":%d},"disk":{"consumed_mb":%d},"storage_baseline":%s,"phases":%s,"milestones":%s,"oom_detected":%s,"oom_details":"%s"}' \
	"$DURATION_SEC" "$JOB_OFFSET_SEC" "$SAMPLE_COUNT" \
	"$CPU_AVG" "$CPU_PEAK" "$CPU_STEAL_MAX" \
	"$MEM_INIT_MB" "$MEM_PEAK_MB" "$MEM_FINAL_MB" "$MEM_TOTAL_MB" "$MEM_PEAK_PCT" \
	"$SWAP_INIT_MB" "$SWAP_PEAK_MB" "$SWAP_FINAL_MB" "$SWAP_TOTAL_MB" \
	"$NET_RX_MB" "$NET_TX_MB" \
	"$DISK_READ_MB" "$DISK_WRITE_MB" \
	"$GPU_AVG" "$GPU_PEAK" "$VRAM_PEAK_MB" "$VRAM_TOTAL_MB" \
	"$DISK_CONSUMED_MB" "$STORAGE_BASELINE_JSON" "$PHASES_JSON" "$MILESTONES_JSON" "$OOM_DETECTED" "$ESCAPED_OOM_DETAILS")

echo "$SUMMARY_JSON" >|"$SUMMARY_FILE"

# 7. Write to $GITHUB_STEP_SUMMARY
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo "## 📊 Runner Telemetry & Resource Summary"
		echo ""
		if [ "$OOM_DETECTED" = "true" ]; then
			echo "> [!CAUTION]"
			case "$TARGET_OS" in
			"Windows")
				echo "> **Resource Exhaustion / Out-Of-Memory Detected!**"
				echo "> The Windows operating system detected a critical low virtual memory condition."
				;;
			"macOS")
				echo "> **Out-Of-Memory (Jetsam) Kill Detected!**"
				echo "> The macOS kernel terminated one or more processes due to memory exhaustion."
				;;
			*)
				echo "> **Out-Of-Memory (OOM) Kill Detected!**"
				echo "> The Linux kernel terminated one or more processes due to memory exhaustion."
				;;
			esac
			[ -n "$OOM_DETAILS" ] && echo "> Details: \`${OOM_DETAILS}\`"
			echo ""
		fi
		echo "| Metric | Baseline / Min | Peak / Max | Final / Avg | Trend |"
		echo "| :--- | :--- | :--- | :--- | :--- |"
		[ "$ENABLE_CPU" = "true" ] && echo "| **CPU Utilization** | — | **${CPU_PEAK}%** | Avg: **${CPU_AVG}%** | \`${CPU_SPARKLINE}\` |"
		[ "$ENABLE_MEM" = "true" ] && echo "| **Memory Usage** | ${MEM_INIT_MB} MB | **${MEM_PEAK_MB} MB** (${MEM_PEAK_PCT}%) | ${MEM_FINAL_MB} MB / ${MEM_TOTAL_MB} MB | \`${MEM_SPARKLINE}\` |"
		[ "$ENABLE_SWAP" = "true" ] && echo "| **Swap Usage** | ${SWAP_INIT_MB} MB | **${SWAP_PEAK_MB} MB** | ${SWAP_FINAL_MB} MB / ${SWAP_TOTAL_MB} MB | \`${SWAP_SPARKLINE}\` |"
		[ "$ENABLE_NET" = "true" ] && echo "| **Network I/O** | — | RX: **${NET_RX_MB} MB** | TX: **${NET_TX_MB} MB** | \`${NET_SPARKLINE}\` |"
		[ "$ENABLE_DISK_IO" = "true" ] && echo "| **Disk I/O** | — | Read: **${DISK_READ_MB} MB** | Write: **${DISK_WRITE_MB} MB** | \`${DISK_IO_SPARKLINE}\` |"
		[ "$ENABLE_GPU" = "true" ] && echo "| **GPU Utilization** | — | **${GPU_PEAK}%** | Avg: **${GPU_AVG}%** | \`${GPU_SPARKLINE}\` |"
		[ "$ENABLE_GPU" = "true" ] && echo "| **GPU VRAM** | — | **${VRAM_PEAK_MB} MB** | Total: ${VRAM_TOTAL_MB} MB | \`${VRAM_SPARKLINE}\` |"
		if [ -n "$ROOT_TOTAL_BYTES" ] && [ "$ROOT_TOTAL_BYTES" -gt 0 ]; then
			if [ "$ENABLE_DISK" = "true" ]; then
				echo "| **Disk Consumed & Baseline** | Pre-installed: **${ROOT_USED_GB} GB** (${ROOT_USED_PCT}%) | Net Consumed: **${DISK_CONSUMED_MB} MB** | Free: **${ROOT_FREE_GB} GB** / ${ROOT_TOTAL_GB} GB | — |"
			else
				echo "| **Disk Storage Baseline** | Pre-installed: **${ROOT_USED_GB} GB** (${ROOT_USED_PCT}%) | — | Free: **${ROOT_FREE_GB} GB** / ${ROOT_TOTAL_GB} GB | — |"
			fi
		elif [ "$ENABLE_DISK" = "true" ]; then
			echo "| **Disk Consumed** | — | Net: **${DISK_CONSUMED_MB} MB** | — | — |"
		fi
		[ "$ENABLE_CPU" = "true" ] && [ "$CPU_STEAL_MAX" -gt 0 ] && echo "| **CPU Steal (Contention)** | — | **${CPU_STEAL_MAX}%** ⚠️ | Hypervisor throttling detected | — |"
		echo ""
		if [ -n "$PHASE_TABLE_ROWS" ]; then
			echo "### ⏱️ Phase Breakdown"
			echo ""
			echo "| Phase / Milestone | Duration / Offset | Peak RAM | Avg CPU | Disk Consumed / Free |"
			echo "| :--- | :--- | :--- | :--- | :--- |"
			echo "$PHASE_TABLE_ROWS"
			echo "| **Total Job** | ${DURATION_SEC}s | ${MEM_PEAK_MB} MB | ${CPU_AVG}% | ${DISK_CONSUMED_MB} MB |"
			echo ""
		fi
		if [ -s "$CHART_FILE" ]; then
			echo "### Resource Utilization Timeline"
			echo ""
			cat "$CHART_FILE"
			echo ""
		fi
		if [ -s "$IO_CHART_FILE" ]; then
			echo "### I/O Throughput Timeline"
			echo ""
			cat "$IO_CHART_FILE"
			echo ""
		fi
		if [ -s "$GANTT_FILE" ]; then
			cat "$GANTT_FILE"
			echo ""
		fi
		HUMAN_DUR=$(printf "%02d:%02d:%02d:%02d" "$((DURATION_SEC / 86400))" "$(((DURATION_SEC % 86400) / 3600))" "$(((DURATION_SEC % 3600) / 60))" "$((DURATION_SEC % 60))")
		if [ "$JOB_OFFSET_SEC" -gt 0 ]; then
			echo "*Duration: ${HUMAN_DUR} (${DURATION_SEC}s · ${SAMPLE_COUNT} samples · started +${JOB_OFFSET_SEC}s after job start)*"
		else
			echo "*Duration: ${HUMAN_DUR} (${DURATION_SEC}s · ${SAMPLE_COUNT} samples)*"
		fi
		echo ""
	} >>"$GITHUB_STEP_SUMMARY"
fi

# 8. Set Action Outputs
if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		printf "peak_memory_mb=%s\n" "$MEM_PEAK_MB"
		printf "avg_cpu_percent=%s\n" "$CPU_AVG"
		printf "disk_consumed_mb=%s\n" "$DISK_CONSUMED_MB"
		printf "peak_swap_mb=%s\n" "$SWAP_PEAK_MB"
		printf "network_rx_mb=%s\n" "$NET_RX_MB"
		printf "network_tx_mb=%s\n" "$NET_TX_MB"
		printf "disk_read_mb=%s\n" "$DISK_READ_MB"
		printf "disk_write_mb=%s\n" "$DISK_WRITE_MB"
		printf "peak_gpu_percent=%s\n" "$GPU_PEAK"
		printf "peak_vram_mb=%s\n" "$VRAM_PEAK_MB"
		printf "oom_detected=%s\n" "$OOM_DETECTED"
		printf 'summary<<EOF_SUMMARY\n%s\nEOF_SUMMARY\n' "$SUMMARY_JSON"
	} >>"$GITHUB_OUTPUT"
fi
