#!/bin/sh
set -euC

OUT_DIR="${RUNNER_FETCH_DIR:-${RUNNER_TEMP:-/tmp}/runner-fetch}"
ROOT_DIR="${RUNNER_FETCH_ROOT_DIR:-${RUNNER_TEMP:-/tmp}/runner-fetch}"
mkdir -p "$OUT_DIR"
PHASES_FILE="${OUT_DIR}/phases.tsv"
SAMPLES_FILE="${OUT_DIR}/samples.tsv"
ROOT_PHASES_FILE="${ROOT_DIR}/phases.tsv"
ROOT_SAMPLES_FILE="${ROOT_DIR}/samples.tsv"

# If root has a samples.tsv and current scope does not, point SAMPLES_FILE to root
if [ ! -f "$SAMPLES_FILE" ] && [ -f "$ROOT_SAMPLES_FILE" ]; then
	SAMPLES_FILE="$ROOT_SAMPLES_FILE"
fi

PHASE_START="${INPUT_PHASE_START:-}"
PHASE_END="${INPUT_PHASE_END:-}"
MILESTONE="${INPUT_MILESTONE:-}"

NOW=$(date +%s)

if [ -n "$MILESTONE" ]; then
	M_CPU=0
	M_MEM=0
	M_DISK=0
	if [ -f "$SAMPLES_FILE" ]; then
		LAST_LINE=$(tail -n 1 "$SAMPLES_FILE" 2>/dev/null || true)
		case "$LAST_LINE" in
		"" | epoch*) ;;
		*)
			M_CPU=$(echo "$LAST_LINE" | awk -F'\t' '{print int($6)}')
			M_MEM=$(echo "$LAST_LINE" | awk -F'\t' '{print int($7)}')
			M_DISK=$(echo "$LAST_LINE" | awk -F'\t' '{print int($9)}')
			;;
		esac
	fi
	if [ "$M_MEM" -eq 0 ] && [ -r /proc/meminfo ]; then
		M_MEM=$(awk '/MemTotal:/ {tot=$2} /MemAvailable:/ {avail=$2} END {print int((tot-avail)/1024)}' /proc/meminfo 2>/dev/null || echo 0)
	fi
	if [ "$M_DISK" -eq 0 ] && command -v df >/dev/null 2>&1; then
		DF_TARGET="/"
		case "${RUNNER_OS:-$(uname -s 2>/dev/null || echo '')}" in
		Windows* | CYGWIN* | MINGW* | MSYS*) DF_TARGET="/c" ;;
		esac
		M_DISK=$(df -k -P "$DF_TARGET" 2>/dev/null | awk 'NR == 2 {print int($4 / 1024)}' || echo 0)
	fi

	printf "MILESTONE\t%s\t%d\t%d\t%d\t%d\n" "$MILESTONE" "$NOW" "${M_MEM:-0}" "${M_CPU:-0}" "${M_DISK:-0}" >>"$PHASES_FILE"
	if [ "$OUT_DIR" != "$ROOT_DIR" ] && [ -d "$ROOT_DIR" ]; then
		printf "MILESTONE\t%s\t%d\t%d\t%d\t%d\n" "$MILESTONE" "$NOW" "${M_MEM:-0}" "${M_CPU:-0}" "${M_DISK:-0}" >>"$ROOT_PHASES_FILE"
	fi
	echo "Runner Telemetry: Marked milestone '${MILESTONE}' at epoch ${NOW}"

	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		{
			printf "milestone_name=%s\n" "$MILESTONE"
			printf "milestone_timestamp=%s\n" "$NOW"
			printf "milestone_memory_mb=%s\n" "${M_MEM:-0}"
			printf "milestone_cpu_percent=%s\n" "${M_CPU:-0}"
			printf "milestone_disk_free_mb=%s\n" "${M_DISK:-0}"
		} >>"$GITHUB_OUTPUT"
	fi
fi

# Handle phase end first so that steps transitioning between phases complete the preceding phase before starting the next.
if [ -n "$PHASE_END" ]; then
	printf "END\t%d\t%s\n" "$NOW" "$PHASE_END" >>"$PHASES_FILE"
	if [ "$OUT_DIR" != "$ROOT_DIR" ] && [ -d "$ROOT_DIR" ]; then
		printf "END\t%d\t%s\n" "$NOW" "$PHASE_END" >>"$ROOT_PHASES_FILE"
	fi
	echo "Runner Telemetry: Marked phase end '${PHASE_END}' at epoch ${NOW}"

	# If samples.tsv exists, calculate metrics specifically for this phase
	START_EPOCH=0
	for pf in "$PHASES_FILE" "$ROOT_PHASES_FILE"; do
		if [ -f "$pf" ] && [ "${START_EPOCH:-0}" -eq 0 ]; then
			s=$(awk -F'\t' -v name="$PHASE_END" '$1 == "START" && $3 == name { s = $2 } END { print s }' "$pf")
			[ -n "$s" ] && START_EPOCH="$s"
		fi
	done

	PHASE_DUR=0
	PHASE_PEAK_MEM=0
	PHASE_AVG_CPU=0
	PHASE_DISK_CONSUMED=0

	if [ -n "$START_EPOCH" ] && [ "$START_EPOCH" -gt 0 ] && [ -f "$SAMPLES_FILE" ]; then
		PHASE_STATS=$(awk -F'\t' -v s_epoch="$START_EPOCH" -v e_epoch="$NOW" '
		NR > 1 {
			epoch = $1; cpu = $6; mem = $7; disk = $9
			last_known_mem = mem
			if (epoch >= s_epoch && epoch <= e_epoch) {
				count++
				cpu_sum += cpu
				if (cpu > peak_cpu) peak_cpu = cpu
				if (mem > peak_mem) peak_mem = mem
				if (count == 1) d_init = disk
				d_final = disk
			}
		}
		END {
			dur = e_epoch - s_epoch
			if (dur < 0) dur = 0
			if (count == 0) {
				peak_mem = last_known_mem
				avg_c = 0
				d_con = 0
			} else {
				avg_c = int(cpu_sum / count)
				d_con = d_init - d_final
				if (d_con < 0) d_con = 0
			}
			printf "%d\t%d\t%d\t%d\n", dur, peak_mem, avg_c, d_con
		}' "$SAMPLES_FILE")

		IFS='	' read -r PHASE_DUR PHASE_PEAK_MEM PHASE_AVG_CPU PHASE_DISK_CONSUMED <<EOF
$PHASE_STATS
EOF
	fi

	# Persist summary line for post summary breakdown table
	printf "SUMMARY\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n" "$PHASE_END" "$PHASE_DUR" "$PHASE_PEAK_MEM" "$PHASE_AVG_CPU" "$PHASE_DISK_CONSUMED" "${START_EPOCH:-$NOW}" "$NOW" >>"$PHASES_FILE"
	if [ "$OUT_DIR" != "$ROOT_DIR" ] && [ -d "$ROOT_DIR" ]; then
		printf "SUMMARY\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n" "$PHASE_END" "$PHASE_DUR" "$PHASE_PEAK_MEM" "$PHASE_AVG_CPU" "$PHASE_DISK_CONSUMED" "${START_EPOCH:-$NOW}" "$NOW" >>"$ROOT_PHASES_FILE"
	fi

	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		{
			printf "phase_name=%s\n" "$PHASE_END"
			printf "phase_duration_seconds=%s\n" "$PHASE_DUR"
			printf "phase_peak_memory_mb=%s\n" "$PHASE_PEAK_MEM"
			printf "phase_avg_cpu_percent=%s\n" "$PHASE_AVG_CPU"
			printf "phase_disk_consumed_mb=%s\n" "$PHASE_DISK_CONSUMED"
		} >>"$GITHUB_OUTPUT"
	fi
fi

if [ -n "$PHASE_START" ]; then
	printf "START\t%d\t%s\n" "$NOW" "$PHASE_START" >>"$PHASES_FILE"
	if [ "$OUT_DIR" != "$ROOT_DIR" ] && [ -d "$ROOT_DIR" ]; then
		printf "START\t%d\t%s\n" "$NOW" "$PHASE_START" >>"$ROOT_PHASES_FILE"
	fi
	echo "Runner Telemetry: Marked phase start '${PHASE_START}' at epoch ${NOW}"
fi
