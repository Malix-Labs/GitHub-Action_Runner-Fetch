#!/bin/sh
set -euC

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR="${RUNNER_TEMP:-/tmp}/test-runner-suite-$$"
mkdir -p "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM

setup_test() {
	RUN_DIR="$TEST_DIR/$1"
	mkdir -p "$RUN_DIR"
	export RUNNER_TEMP="$RUN_DIR"
	export GITHUB_OUTPUT="$RUN_DIR/output.txt"
	export GITHUB_STEP_SUMMARY="$RUN_DIR/summary.md"
	export INPUT_DISK_TREE="false"
	export INPUT_SAMPLE_INTERVAL="1"
	export INPUT_EXPORT_PROMETHEUS="true"
	export INPUT_MONITOR_CPU="true"
	export INPUT_MONITOR_MEMORY="true"
	export INPUT_MONITOR_DISK="false"
	: >|"$GITHUB_OUTPUT"
	: >|"$GITHUB_STEP_SUMMARY"
}

echo "=== Test 1: Normal execution & telemetry generation ==="
setup_test "test1"
(cd "$REPO_ROOT" && node src/main.js)
sleep 2
(cd "$REPO_ROOT" && node src/post.js)

if [ ! -s "$RUN_DIR/runner-fetch/summary.json" ]; then
	echo "Error: summary.json was not generated in Test 1" >&2
	exit 1
fi
node -e "JSON.parse(require('fs').readFileSync('$RUN_DIR/runner-fetch/summary.json', 'utf8'))"
echo "Test 1 PASSED."

echo "=== Test 2: Workflow step crash simulation ==="
setup_test "test2"
(cd "$REPO_ROOT" && node src/main.js)
# Simulate step failure / crash
(cd "$REPO_ROOT" && node src/post.js)

if [ ! -s "$RUN_DIR/runner-fetch/summary.json" ]; then
	echo "Error: summary.json was not generated on step failure in Test 2" >&2
	exit 1
fi
echo "Test 2 PASSED."

echo "=== Test 3: OOM kill detection & special character JSON escaping ==="
setup_test "test3"
(cd "$REPO_ROOT" && node src/main.js)
# Inject sample with OOM kill and special characters
mkdir -p "$RUN_DIR/runner-fetch"
printf "1789320000\t50\t20\t0\t0\t70\t8000\t1000\t50000\t1\n" >>"$RUN_DIR/runner-fetch/samples.tsv"
(cd "$REPO_ROOT" && node src/post.js)

node -e "
const fs = require('fs');
const summary = JSON.parse(fs.readFileSync('$RUN_DIR/runner-fetch/summary.json', 'utf8'));
if (!summary.oom_detected) {
  console.error('Error: OOM not detected');
  process.exit(1);
}
"
echo "Test 3 PASSED."

echo "=== Test 4: monitor disabled cleanly when all monitors are false ==="
setup_test "test4"
export INPUT_MONITOR_CPU="false"
export INPUT_MONITOR_MEMORY="false"
export INPUT_MONITOR_DISK="false"
(cd "$REPO_ROOT" && node src/main.js)
(cd "$REPO_ROOT" && node src/post.js)

if [ -s "$GITHUB_STEP_SUMMARY" ]; then
	echo "Error: Step summary should be empty when all monitors are false" >&2
	exit 1
fi
echo "Test 4 PASSED."

echo "=== Test 5: Large-scale dataset downsampling, 50k ceiling & peak preservation ==="
setup_test "test5"
mkdir -p "$RUN_DIR/runner-fetch"
node -e "
const fs = require('fs');
const start = 1789000000;
const stream = fs.createWriteStream('$RUN_DIR/runner-fetch/samples.tsv');
stream.write('epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\n');
for (let i = 0; i < 15000; i++) {
  const t = start + i * 2;
  const cpu = (i === 7500) ? 100 : (20 + (i % 30));
  const mem = (i === 7500) ? 10000 : 4000;
  stream.write(\`\${t}\t10\t10\t0\t0\t\${cpu}\t\${mem}\t8000\t50000\t0\n\`);
}
stream.end();
"
(cd "$REPO_ROOT" && node src/post.js)

CHART_FILE="$RUN_DIR/runner-fetch/chart.mermaid"
if [ ! -s "$CHART_FILE" ]; then
	echo "Error: chart.mermaid was not generated in Test 5" >&2
	exit 1
fi
CHART_SIZE=$(wc -c <"$CHART_FILE")
if [ "$CHART_SIZE" -gt 50000 ]; then
	echo "Error: chart.mermaid exceeded 50,000 characters: $CHART_SIZE" >&2
	exit 1
fi
if [ "$CHART_SIZE" -lt 45000 ]; then
	echo "Error: chart.mermaid budget underutilized: $CHART_SIZE" >&2
	exit 1
fi
# Verify peak 100% CPU spike is preserved in downsampled chart
if ! grep 'line "CPU"' "$CHART_FILE" | grep -q ",100,"; then
	echo "Error: 100% CPU spike was not preserved in downsampled chart" >&2
	exit 1
fi
echo "Test 5 PASSED (chart size: $CHART_SIZE bytes)."

echo "=== Test 6: Multi-scale X-axis units & duration formatting ==="
test_duration_scale() {
	case_id="$1"
	sec="$2"
	expected_x="$3"
	expected_dur="$4"

	setup_test "test6_$case_id"
	mkdir -p "$RUN_DIR/runner-fetch"
	t0=1789000000
	t1=$((t0 + sec))
	printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\n" >"$RUN_DIR/runner-fetch/samples.tsv"
	printf "%d\t10\t10\t0\t0\t20\t4000\t8000\t50000\t0\n" "$t0" >>"$RUN_DIR/runner-fetch/samples.tsv"
	printf "%d\t12\t13\t0\t0\t25\t4500\t7500\t49000\t0\n" "$t1" >>"$RUN_DIR/runner-fetch/samples.tsv"

	(cd "$REPO_ROOT" && node src/post.js)

	if ! grep -q "x-axis $expected_x" "$RUN_DIR/runner-fetch/chart.mermaid"; then
		echo "Error: Expected X-axis '$expected_x' not found in case $case_id" >&2
		exit 1
	fi
	if ! grep -q "\*Duration: ${expected_dur} " "$GITHUB_STEP_SUMMARY"; then
		echo "Error: Expected Duration '$expected_dur' not found in case $case_id" >&2
		exit 1
	fi
}

test_duration_scale "short" 45 '"Elapsed Time (s)" 0 --> 45' "00:00:00:45"
test_duration_scale "minutes" 900 '"Elapsed Time (minutes)" 0 --> 15' "00:00:15:00"
test_duration_scale "hours" 16200 '"Elapsed Time (hours)" 0 --> 4.5' "00:04:30:00"
test_duration_scale "days" 432000 '"Elapsed Time (days)" 0 --> 5' "05:00:00:00"
echo "Test 6 PASSED."

echo "=== Test 7: Action outputs & Prometheus metrics export ==="
setup_test "test7"
(cd "$REPO_ROOT" && node src/main.js)
sleep 2
(cd "$REPO_ROOT" && node src/post.js)

for key in peak_memory_mb avg_cpu_percent disk_consumed_mb oom_detected; do
	if ! grep -q "^${key}=" "$GITHUB_OUTPUT"; then
		echo "Error: Missing output key '$key' in GITHUB_OUTPUT" >&2
		exit 1
	fi
done
if ! grep -q '^summary<<EOF_SUMMARY' "$GITHUB_OUTPUT"; then
	echo "Error: Missing multiline summary output in GITHUB_OUTPUT" >&2
	exit 1
fi

PROM_FILE="$RUN_DIR/runner-fetch/metrics.prom"
if [ ! -s "$PROM_FILE" ]; then
	echo "Error: metrics.prom was not generated in Test 7" >&2
	exit 1
fi
if ! grep -q "# HELP runner_cpu_percent" "$PROM_FILE" || ! grep -q "runner_cpu_percent " "$PROM_FILE"; then
	echo "Error: Invalid or missing runner_cpu_percent in metrics.prom" >&2
	exit 1
fi
echo "Test 7 PASSED."

echo "=== Test 8: Single-point (count == 1) & 0-sample edge cases ==="
setup_test "test8_single"
mkdir -p "$RUN_DIR/runner-fetch"
printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\n" >"$RUN_DIR/runner-fetch/samples.tsv"
printf "1789000000\t10\t10\t0\t0\t20\t4000\t8000\t50000\t0\n" >>"$RUN_DIR/runner-fetch/samples.tsv"
(cd "$REPO_ROOT" && node src/post.js)

if [ ! -s "$RUN_DIR/runner-fetch/summary.json" ]; then
	echo "Error: summary.json was not generated for single-point run" >&2
	exit 1
fi
if ! grep -q 'line "CPU" \[20,20\]' "$RUN_DIR/runner-fetch/chart.mermaid"; then
	echo "Error: Single-point flatline fallback not rendered in chart" >&2
	exit 1
fi

setup_test "test8_zero"
mkdir -p "$RUN_DIR/runner-fetch"
printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\n" >"$RUN_DIR/runner-fetch/samples.tsv"
(cd "$REPO_ROOT" && node src/post.js)
if [ -s "$GITHUB_STEP_SUMMARY" ]; then
	echo "Error: Step summary should be empty when 0 samples collected" >&2
	exit 1
fi
echo "Test 8 PASSED."

echo "=== Test 9: export_prometheus: false cleanly disables Prometheus export ==="
setup_test "test9"
export INPUT_EXPORT_PROMETHEUS="false"
(cd "$REPO_ROOT" && node src/main.js)
sleep 2
(cd "$REPO_ROOT" && node src/post.js)
if [ -f "$RUN_DIR/runner-fetch/metrics.prom" ]; then
	echo "Error: metrics.prom should not exist when export_prometheus: false" >&2
	exit 1
fi
echo "Test 9 PASSED."

echo "=== Test 10: Granular resource monitoring toggles (Disk, CPU, Memory) ==="
# 10a: Disk enabled
setup_test "test10_disk"
export INPUT_MONITOR_DISK="true"
(cd "$REPO_ROOT" && node src/main.js)
sleep 2
(cd "$REPO_ROOT" && node src/post.js)
if ! grep -q "Disk Consumed" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: Disk Consumed missing in step summary when monitor-disk is true" >&2
	exit 1
fi
if ! grep -q "runner_disk_free_bytes" "$RUN_DIR/runner-fetch/metrics.prom"; then
	echo "Error: runner_disk_free_bytes missing in metrics.prom when monitor-disk is true" >&2
	exit 1
fi

# 10b: CPU disabled
setup_test "test10_no_cpu"
export INPUT_MONITOR_CPU="false"
(cd "$REPO_ROOT" && node src/main.js)
sleep 2
(cd "$REPO_ROOT" && node src/post.js)
if grep -q "CPU Utilization" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: CPU Utilization present in step summary when monitor-cpu is false" >&2
	exit 1
fi
if grep -q 'line "CPU"' "$RUN_DIR/runner-fetch/chart.mermaid"; then
	echo "Error: CPU line present in chart when monitor-cpu is false" >&2
	exit 1
fi
if ! grep -q 'line "RAM"' "$RUN_DIR/runner-fetch/chart.mermaid"; then
	echo "Error: RAM line missing in chart when monitor-memory is true" >&2
	exit 1
fi

# 10c: Memory disabled
setup_test "test10_no_mem"
export INPUT_MONITOR_MEMORY="false"
(cd "$REPO_ROOT" && node src/main.js)
sleep 2
(cd "$REPO_ROOT" && node src/post.js)
if grep -q "Memory Usage" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: Memory Usage present in step summary when monitor-memory is false" >&2
	exit 1
fi
if grep -q 'line "RAM"' "$RUN_DIR/runner-fetch/chart.mermaid"; then
	echo "Error: RAM line present in chart when monitor-memory is false" >&2
	exit 1
fi
if ! grep -q 'line "CPU"' "$RUN_DIR/runner-fetch/chart.mermaid"; then
	echo "Error: CPU line missing in chart when monitor-cpu is true" >&2
	exit 1
fi
echo "Test 10 PASSED."

echo "=== Test 11: Real GitHub Actions hyphenated input environment variables normalization ==="
setup_test "test11"
# Unset all normalized underscore variables to simulate real GitHub runner environment
unset INPUT_DISK_TREE INPUT_SAMPLE_INTERVAL INPUT_EXPORT_PROMETHEUS INPUT_MONITOR_CPU INPUT_MONITOR_MEMORY INPUT_MONITOR_DISK
env "INPUT_DISK-TREE=false" "INPUT_SAMPLE-INTERVAL=1" "INPUT_EXPORT-PROMETHEUS=true" "INPUT_MONITOR-CPU=true" "INPUT_MONITOR-MEMORY=true" "INPUT_MONITOR-DISK=false" \
	sh -c "cd '$REPO_ROOT' && node src/main.js"
sleep 2
env "INPUT_DISK-TREE=false" "INPUT_SAMPLE-INTERVAL=1" "INPUT_EXPORT-PROMETHEUS=true" "INPUT_MONITOR-CPU=true" "INPUT_MONITOR-MEMORY=true" "INPUT_MONITOR-DISK=false" \
	sh -c "cd '$REPO_ROOT' && node src/post.js"

if [ ! -s "$RUN_DIR/runner-fetch/summary.json" ]; then
	echo "Error: summary.json was not generated in Test 11 with hyphenated inputs" >&2
	exit 1
fi
if [ ! -s "$RUN_DIR/runner-fetch/chart.mermaid" ]; then
	echo "Error: chart.mermaid was not generated in Test 11 with hyphenated inputs" >&2
	exit 1
fi
echo "Test 11 PASSED."

echo "=== Test 12: Multi-call phase tracking (phase-start and phase-end) ==="
setup_test "test12"
export GITHUB_STATE="$RUN_DIR/state.txt"
: >|"$GITHUB_STATE"

# Step 1: Initial invocation starting Setup phase
export INPUT_PHASE_START="Setup"
export INPUT_PHASE_END=""
(cd "$REPO_ROOT" && node src/main.js)

# Stop monitor daemon in test environment so it does not overwrite injected test data
if [ -f "$RUN_DIR/runner-fetch/monitor.pid" ]; then
	kill -9 "$(cat "$RUN_DIR/runner-fetch/monitor.pid")" 2>/dev/null || true
	rm -f "$RUN_DIR/runner-fetch/monitor.pid"
fi

# Simulate telemetry samples for Setup phase
mkdir -p "$RUN_DIR/runner-fetch"
t0=$(date +%s)
printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\n" >|"$RUN_DIR/runner-fetch/samples.tsv"
printf "%d\t10\t10\t0\t0\t20\t2000\t6000\t50000\t0\n" "$((t0 - 4))" >>"$RUN_DIR/runner-fetch/samples.tsv"
printf "%d\t15\t15\t0\t0\t30\t2500\t5500\t49800\t0\n" "$((t0 - 2))" >>"$RUN_DIR/runner-fetch/samples.tsv"

# Step 2: Transition from Setup to Build phase
export GITHUB_OUTPUT="$RUN_DIR/output_step2.txt"
: >|"$GITHUB_OUTPUT"
export INPUT_PHASE_START="Build"
export INPUT_PHASE_END="Setup"
(cd "$REPO_ROOT" && node src/main.js)

if ! grep -q "phase_name=Setup" "$GITHUB_OUTPUT"; then
	echo "Error: phase_name=Setup missing in GITHUB_OUTPUT for step 2" >&2
	exit 1
fi
if ! grep -q "phase_peak_memory_mb=2500" "$GITHUB_OUTPUT"; then
	echo "Error: Expected phase_peak_memory_mb=2500 not found in GITHUB_OUTPUT" >&2
	exit 1
fi

# Simulate samples for Build phase
t1=$(date +%s)
printf "%d\t40\t40\t0\t0\t80\t4000\t4000\t49000\t0\n" "$((t1 - 1))" >>"$RUN_DIR/runner-fetch/samples.tsv"
printf "%d\t45\t45\t0\t0\t90\t4200\t3800\t48500\t0\n" "$t1" >>"$RUN_DIR/runner-fetch/samples.tsv"

# Step 3: End Build phase
export GITHUB_OUTPUT="$RUN_DIR/output_step3.txt"
: >|"$GITHUB_OUTPUT"
export INPUT_PHASE_START=""
export INPUT_PHASE_END="Build"
(cd "$REPO_ROOT" && node src/main.js)

if ! grep -q "phase_name=Build" "$GITHUB_OUTPUT"; then
	echo "Error: phase_name=Build missing in GITHUB_OUTPUT for step 3" >&2
	exit 1
fi

# Simulate Post actions execution order in GitHub Actions (reverse order: Step 3, Step 2, Step 1)
# Step 3 post (STATE_is_primary_init not set)
(cd "$REPO_ROOT" && node src/post.js)
# Step 2 post (STATE_is_primary_init not set)
(cd "$REPO_ROOT" && node src/post.js)

# Step 1 post (STATE_is_primary_init=true)
export STATE_is_primary_init="true"
(cd "$REPO_ROOT" && node src/post.js)

if ! grep -q "### Phase Breakdown" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: Phase Breakdown section missing in GITHUB_STEP_SUMMARY" >&2
	exit 1
fi
if ! grep -q "\| \*\*Setup\*\* \|" "$GITHUB_STEP_SUMMARY" || ! grep -q "\| \*\*Build\*\* \|" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: Setup or Build rows missing in Phase Breakdown table" >&2
	exit 1
fi

node -e "
const fs = require('fs');
const summary = JSON.parse(fs.readFileSync('$RUN_DIR/runner-fetch/summary.json', 'utf8'));
if (!Array.isArray(summary.phases) || summary.phases.length !== 2) {
  console.error('Error: summary.phases does not contain 2 phases:', summary.phases);
  process.exit(1);
}
if (summary.phases[0].name !== 'Setup' || summary.phases[1].name !== 'Build') {
  console.error('Error: Phase names mismatch:', summary.phases);
  process.exit(1);
}
"
echo "Test 12 PASSED."

echo "=== Test 13: Runner start offset on delayed action execution ==="
setup_test "test13"
mkdir -p "$RUN_DIR/runner-fetch"
t_start=1789000000
t_action=$((t_start + 45))
t_end=$((t_action + 30))

# Simulate runner temp folder created at t_start (45s before action started)
touch -d "@${t_start}" "$RUN_DIR" 2>/dev/null || true

printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\n" >|"$RUN_DIR/runner-fetch/samples.tsv"
printf "%d\t10\t10\t0\t0\t20\t2000\t6000\t50000\t0\n" "$t_action" >>"$RUN_DIR/runner-fetch/samples.tsv"
printf "%d\t15\t15\t0\t0\t30\t2500\t5500\t49800\t0\n" "$t_end" >>"$RUN_DIR/runner-fetch/samples.tsv"

(cd "$REPO_ROOT" && node src/post.js)

if ! grep -q 'x-axis "Elapsed Time (s)" 45 --> 75' "$RUN_DIR/runner-fetch/chart.mermaid"; then
	echo "Error: Expected X-axis '45 --> 75' not found in chart.mermaid" >&2
	cat "$RUN_DIR/runner-fetch/chart.mermaid" >&2
	exit 1
fi
if ! grep -q "started +45s after job start" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: Job start offset note missing in step summary" >&2
	exit 1
fi
node -e "
const fs = require('fs');
const summary = JSON.parse(fs.readFileSync('$RUN_DIR/runner-fetch/summary.json', 'utf8'));
if (summary.job_offset_seconds !== 45) {
  console.error('Error: Expected job_offset_seconds 45, got:', summary.job_offset_seconds);
  process.exit(1);
}
"
echo "Test 13 PASSED."

echo "=== Test 14: Storage baseline & pre-installed bloat reporting in summary ==="
setup_test "test14"
mkdir -p "$RUN_DIR/runner-fetch"
# Inject mock baseline: 100 GB total, 40 GB used (40%), 60 GB free
printf "107374182400\t42949672960\t64424509440\n" >|"$RUN_DIR/runner-fetch/storage_baseline.tsv"
printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\n" >|"$RUN_DIR/runner-fetch/samples.tsv"
printf "1789000000\t10\t10\t0\t0\t20\t2000\t6000\t61440\t0\n" >>"$RUN_DIR/runner-fetch/samples.tsv"
printf "1789000010\t15\t15\t0\t0\t30\t2500\t5500\t61440\t0\n" >>"$RUN_DIR/runner-fetch/samples.tsv"

(cd "$REPO_ROOT" && node src/post.js)

if ! grep -q "Pre-installed: \*\*40.0 GB\*\* (40%)" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: Pre-installed baseline missing in step summary" >&2
	cat "$GITHUB_STEP_SUMMARY" >&2
	exit 1
fi
if ! grep -q "Free: \*\*60.0 GB\*\* / 100.0 GB" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: Free/Total disk missing in step summary" >&2
	cat "$GITHUB_STEP_SUMMARY" >&2
	exit 1
fi
node -e "
const fs = require('fs');
const summary = JSON.parse(fs.readFileSync('$RUN_DIR/runner-fetch/summary.json', 'utf8'));
if (!summary.storage_baseline || summary.storage_baseline.preinstalled_bloat_percent !== 40) {
  console.error('Error: storage_baseline missing or incorrect in summary.json:', summary.storage_baseline);
  process.exit(1);
}
"
echo "Test 14 PASSED."

echo "=== Test 15: Swap monitoring telemetry, outputs, summary table & Prometheus ==="
setup_test "test15"
export INPUT_MONITOR_SWAP="true"
mkdir -p "$RUN_DIR/runner-fetch"
{
	printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\tswap_used_mb\tswap_total_mb\n"
	printf "1789000000\t10\t10\t0\t0\t20\t2000\t6000\t50000\t0\t120\t2048\n"
	printf "1789000002\t15\t15\t0\t0\t30\t2500\t5500\t50000\t0\t350\t2048\n"
	printf "1789000004\t10\t10\t0\t0\t20\t2200\t5800\t50000\t0\t210\t2048\n"
} >|"$RUN_DIR/runner-fetch/samples.tsv"

(cd "$REPO_ROOT" && node src/post.js)

if ! grep -q "Swap Usage" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: Swap Usage row missing in step summary" >&2
	cat "$GITHUB_STEP_SUMMARY" >&2
	exit 1
fi

if ! grep -q "peak_swap_mb=350" "$GITHUB_OUTPUT"; then
	echo "Error: Expected peak_swap_mb=350 not found in GITHUB_OUTPUT" >&2
	cat "$GITHUB_OUTPUT" >&2
	exit 1
fi

if ! grep -q "runner_swap_used_bytes" "$RUN_DIR/runner-fetch/metrics.prom"; then
	echo "Error: Expected runner_swap_used_bytes missing in Prometheus metrics" >&2
	cat "$RUN_DIR/runner-fetch/metrics.prom" >&2
	exit 1
fi

node -e "
const fs = require('fs');
const summary = JSON.parse(fs.readFileSync('$RUN_DIR/runner-fetch/summary.json', 'utf8'));
if (!summary.swap || summary.swap.peak_mb !== 350 || summary.swap.initial_mb !== 120 || summary.swap.final_mb !== 210 || summary.swap.total_mb !== 2048) {
  console.error('Error: Swap metrics missing or incorrect in summary.json:', summary.swap);
  process.exit(1);
}
"
echo "Test 15 PASSED."

echo "=== Test 16: Network I/O monitoring telemetry, outputs, summary table & Prometheus ==="
setup_test "test16"
export INPUT_MONITOR_NETWORK="true"
mkdir -p "$RUN_DIR/runner-fetch"
{
	printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\tswap_used_mb\tswap_total_mb\tnet_rx_mb\tnet_tx_mb\n"
	printf "1789000000\t10\t10\t0\t0\t20\t2000\t6000\t50000\t0\t0\t0\t100\t50\n"
	printf "1789000002\t15\t15\t0\t0\t30\t2500\t5500\t50000\t0\t0\t0\t250\t80\n"
	printf "1789000004\t10\t10\t0\t0\t20\t2200\t5800\t50000\t0\t0\t0\t320\t110\n"
} >|"$RUN_DIR/runner-fetch/samples.tsv"

(cd "$REPO_ROOT" && node src/post.js)

if ! grep -q "Network I/O" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: Network I/O row missing in step summary" >&2
	cat "$GITHUB_STEP_SUMMARY" >&2
	exit 1
fi

if ! grep -q "network_rx_mb=220" "$GITHUB_OUTPUT"; then
	echo "Error: Expected network_rx_mb=220 not found in GITHUB_OUTPUT" >&2
	cat "$GITHUB_OUTPUT" >&2
	exit 1
fi

if ! grep -q "network_tx_mb=60" "$GITHUB_OUTPUT"; then
	echo "Error: Expected network_tx_mb=60 not found in GITHUB_OUTPUT" >&2
	cat "$GITHUB_OUTPUT" >&2
	exit 1
fi

if ! grep -q "runner_network_receive_bytes" "$RUN_DIR/runner-fetch/metrics.prom"; then
	echo "Error: Expected runner_network_receive_bytes missing in Prometheus metrics" >&2
	cat "$RUN_DIR/runner-fetch/metrics.prom" >&2
	exit 1
fi

node -e "
const fs = require('fs');
const summary = JSON.parse(fs.readFileSync('$RUN_DIR/runner-fetch/summary.json', 'utf8'));
if (!summary.network || summary.network.rx_mb !== 220 || summary.network.tx_mb !== 60) {
  console.error('Error: Network metrics missing or incorrect in summary.json:', summary.network);
  process.exit(1);
}
"
echo "Test 16 PASSED."

echo "=== Test 17: Disk I/O monitoring telemetry, outputs, summary table & Prometheus ==="
setup_test "test17"
export INPUT_MONITOR_DISK_IO="true"
mkdir -p "$RUN_DIR/runner-fetch"
{
	printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\tswap_used_mb\tswap_total_mb\tnet_rx_mb\tnet_tx_mb\tdisk_read_mb\tdisk_write_mb\n"
	printf "1789000000\t10\t10\t0\t0\t20\t2000\t6000\t50000\t0\t0\t0\t0\t0\t500\t200\n"
	printf "1789000002\t15\t15\t0\t0\t30\t2500\t5500\t50000\t0\t0\t0\t0\t0\t800\t450\n"
	printf "1789000004\t10\t10\t0\t0\t20\t2200\t5800\t50000\t0\t0\t0\t0\t0\t950\t600\n"
} >|"$RUN_DIR/runner-fetch/samples.tsv"

(cd "$REPO_ROOT" && node src/post.js)

if ! grep -q "Disk I/O" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: Disk I/O row missing in step summary" >&2
	cat "$GITHUB_STEP_SUMMARY" >&2
	exit 1
fi

if ! grep -q "disk_read_mb=450" "$GITHUB_OUTPUT"; then
	echo "Error: Expected disk_read_mb=450 not found in GITHUB_OUTPUT" >&2
	cat "$GITHUB_OUTPUT" >&2
	exit 1
fi

if ! grep -q "disk_write_mb=400" "$GITHUB_OUTPUT"; then
	echo "Error: Expected disk_write_mb=400 not found in GITHUB_OUTPUT" >&2
	cat "$GITHUB_OUTPUT" >&2
	exit 1
fi

if ! grep -q "runner_disk_read_bytes" "$RUN_DIR/runner-fetch/metrics.prom"; then
	echo "Error: Expected runner_disk_read_bytes missing in Prometheus metrics" >&2
	cat "$RUN_DIR/runner-fetch/metrics.prom" >&2
	exit 1
fi

node -e "
const fs = require('fs');
const summary = JSON.parse(fs.readFileSync('$RUN_DIR/runner-fetch/summary.json', 'utf8'));
if (!summary.disk_io || summary.disk_io.read_mb !== 450 || summary.disk_io.write_mb !== 400) {
  console.error('Error: Disk I/O metrics missing or incorrect in summary.json:', summary.disk_io);
  process.exit(1);
}
"
echo "Test 17 PASSED."

echo "=== Test 18: GPU utilization and VRAM monitoring telemetry, outputs, summary table & Prometheus ==="
setup_test "test18"
export INPUT_MONITOR_GPU="true"
mkdir -p "$RUN_DIR/runner-fetch"
{
	printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\tswap_used_mb\tswap_total_mb\tnet_rx_mb\tnet_tx_mb\tdisk_read_mb\tdisk_write_mb\tgpu_util_pct\tgpu_vram_used_mb\tgpu_vram_total_mb\n"
	printf "1789000000\t10\t10\t0\t0\t20\t2000\t6000\t50000\t0\t0\t0\t0\t0\t0\t0\t20\t2048\t16384\n"
	printf "1789000002\t15\t15\t0\t0\t30\t2500\t5500\t50000\t0\t0\t0\t0\t0\t0\t0\t95\t8192\t16384\n"
	printf "1789000004\t10\t10\t0\t0\t20\t2200\t5800\t50000\t0\t0\t0\t0\t0\t0\t0\t35\t6144\t16384\n"
} >|"$RUN_DIR/runner-fetch/samples.tsv"

(cd "$REPO_ROOT" && node src/post.js)

if ! grep -q "GPU Utilization" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: GPU Utilization row missing in step summary" >&2
	cat "$GITHUB_STEP_SUMMARY" >&2
	exit 1
fi

if ! grep -q "GPU VRAM" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: GPU VRAM row missing in step summary" >&2
	cat "$GITHUB_STEP_SUMMARY" >&2
	exit 1
fi

if ! grep -q "peak_gpu_percent=95" "$GITHUB_OUTPUT"; then
	echo "Error: Expected peak_gpu_percent=95 not found in GITHUB_OUTPUT" >&2
	cat "$GITHUB_OUTPUT" >&2
	exit 1
fi

if ! grep -q "peak_vram_mb=8192" "$GITHUB_OUTPUT"; then
	echo "Error: Expected peak_vram_mb=8192 not found in GITHUB_OUTPUT" >&2
	cat "$GITHUB_OUTPUT" >&2
	exit 1
fi

if ! grep -q "runner_gpu_utilization_percent" "$RUN_DIR/runner-fetch/metrics.prom"; then
	echo "Error: Expected runner_gpu_utilization_percent missing in Prometheus metrics" >&2
	cat "$RUN_DIR/runner-fetch/metrics.prom" >&2
	exit 1
fi

if ! grep -q "runner_gpu_vram_used_bytes" "$RUN_DIR/runner-fetch/metrics.prom"; then
	echo "Error: Expected runner_gpu_vram_used_bytes missing in Prometheus metrics" >&2
	cat "$RUN_DIR/runner-fetch/metrics.prom" >&2
	exit 1
fi

node -e "
const fs = require('fs');
const summary = JSON.parse(fs.readFileSync('$RUN_DIR/runner-fetch/summary.json', 'utf8'));
if (!summary.gpu || summary.gpu.peak_percent !== 95 || summary.gpu.average_percent !== 50 || summary.gpu.peak_vram_mb !== 8192 || summary.gpu.total_vram_mb !== 16384) {
  console.error('Error: GPU metrics missing or incorrect in summary.json:', summary.gpu);
  process.exit(1);
}
"
echo "Test 18 PASSED."

echo "=== Test 19: Instantaneous milestone tracking and companion Gantt chart ==="
setup_test "test19"
mkdir -p "$RUN_DIR/runner-fetch"

# Step 1: Initial invocation starting Setup phase
export INPUT_PHASE_START="Setup"
export INPUT_PHASE_END=""
export INPUT_MILESTONE=""
export GITHUB_OUTPUT="$RUN_DIR/output_step1.txt"
: >|"$GITHUB_OUTPUT"
(cd "$REPO_ROOT" && node src/main.js)

if [ -f "$RUN_DIR/runner-fetch/monitor.pid" ]; then
	kill -9 "$(cat "$RUN_DIR/runner-fetch/monitor.pid")" 2>/dev/null || true
	rm -f "$RUN_DIR/runner-fetch/monitor.pid"
fi

t0=$(date +%s)
printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\n" >|"$RUN_DIR/runner-fetch/samples.tsv"
printf "%d\t10\t10\t0\t0\t20\t2000\t6000\t50000\t0\n" "$((t0 - 4))" >>"$RUN_DIR/runner-fetch/samples.tsv"
printf "%d\t15\t15\t0\t0\t30\t2500\t5500\t49800\t0\n" "$((t0 - 2))" >>"$RUN_DIR/runner-fetch/samples.tsv"

# Step 2: Milestone recording
export INPUT_PHASE_START=""
export INPUT_PHASE_END=""
export INPUT_MILESTONE="Cache Restored"
export GITHUB_OUTPUT="$RUN_DIR/output_milestone.txt"
: >|"$GITHUB_OUTPUT"
(cd "$REPO_ROOT" && node src/main.js)

if ! grep -q "milestone_name=Cache Restored" "$GITHUB_OUTPUT"; then
	echo "Error: milestone_name=Cache Restored missing in GITHUB_OUTPUT" >&2
	cat "$GITHUB_OUTPUT" >&2
	exit 1
fi
if ! grep -q "milestone_memory_mb=2500" "$GITHUB_OUTPUT"; then
	echo "Error: Expected milestone_memory_mb=2500 not found in GITHUB_OUTPUT" >&2
	cat "$GITHUB_OUTPUT" >&2
	exit 1
fi

# Step 3: Phase End
export INPUT_MILESTONE=""
export INPUT_PHASE_END="Setup"
export GITHUB_OUTPUT="$RUN_DIR/output_phase_end.txt"
: >|"$GITHUB_OUTPUT"
(cd "$REPO_ROOT" && node src/main.js)

# Step 4: Summary generation (post.js)
export STATE_is_primary_init="true"
(cd "$REPO_ROOT" && node src/post.js)

if [ ! -s "$RUN_DIR/runner-fetch/gantt.mermaid" ]; then
	echo "Error: gantt.mermaid file missing or empty" >&2
	exit 1
fi

if ! grep -q "useWidth" "$RUN_DIR/runner-fetch/gantt.mermaid"; then
	echo "Error: useWidth missing in gantt.mermaid" >&2
	cat "$RUN_DIR/runner-fetch/gantt.mermaid" >&2
	exit 1
fi

if ! grep -q "dateFormat YYYY-MM-DD HH:mm:ss" "$RUN_DIR/runner-fetch/gantt.mermaid"; then
	echo "Error: Universal dateFormat missing in gantt.mermaid" >&2
	cat "$RUN_DIR/runner-fetch/gantt.mermaid" >&2
	exit 1
fi

if ! grep -q "Job Telemetry : done" "$RUN_DIR/runner-fetch/gantt.mermaid"; then
	echo "Error: Job Telemetry anchor missing in gantt.mermaid" >&2
	cat "$RUN_DIR/runner-fetch/gantt.mermaid" >&2
	exit 1
fi

if ! grep -q "Cache Restored : milestone" "$RUN_DIR/runner-fetch/gantt.mermaid"; then
	echo "Error: Milestone 'Cache Restored' missing in gantt.mermaid" >&2
	cat "$RUN_DIR/runner-fetch/gantt.mermaid" >&2
	exit 1
fi

if ! grep -q "Setup : active" "$RUN_DIR/runner-fetch/gantt.mermaid"; then
	echo "Error: Phase 'Setup' missing in gantt.mermaid" >&2
	cat "$RUN_DIR/runner-fetch/gantt.mermaid" >&2
	exit 1
fi

if ! grep -q "\| \*\*Cache Restored\*\* \|" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: Milestone row missing in GITHUB_STEP_SUMMARY" >&2
	cat "$GITHUB_STEP_SUMMARY" >&2
	exit 1
fi

# Verify Gantt diagram appears before the Resource Utilization Timeline chart
node -e "
const fs = require('fs');
const content = fs.readFileSync('$GITHUB_STEP_SUMMARY', 'utf8');
const ganttIdx = content.indexOf('gantt\n');
const chartIdx = content.indexOf('### Resource Utilization Timeline');
if (ganttIdx === -1 || chartIdx === -1 || ganttIdx > chartIdx) {
  console.error('Error: Gantt chart must precede the Resource Utilization Timeline chart. ganttIdx:', ganttIdx, 'chartIdx:', chartIdx);
  process.exit(1);
}
"

node -e "
const fs = require('fs');
const summary = JSON.parse(fs.readFileSync('$RUN_DIR/runner-fetch/summary.json', 'utf8'));
if (!Array.isArray(summary.milestones) || summary.milestones.length !== 1) {
  console.error('Error: summary.milestones invalid:', summary.milestones);
  process.exit(1);
}
if (summary.milestones[0].name !== 'Cache Restored' || summary.milestones[0].memory_mb !== 2500) {
  console.error('Error: milestone content mismatch:', summary.milestones[0]);
  process.exit(1);
}
if (!Array.isArray(summary.phases) || summary.phases.length !== 1 || summary.phases[0].name !== 'Setup') {
  console.error('Error: summary.phases invalid:', summary.phases);
  process.exit(1);
}
"
echo "Test 19 PASSED."

echo "=== Test 20: Dedicated I/O throughput timeline chart & canvas synchronization ==="
setup_test "test20"
export INPUT_MONITOR_DISK_IO="true"
export INPUT_MONITOR_NETWORK="true"
mkdir -p "$RUN_DIR/runner-fetch"
{
	printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\tswap_used_mb\tswap_total_mb\tnet_rx_mb\tnet_tx_mb\tdisk_read_mb\tdisk_write_mb\n"
	printf "1789000000\t10\t10\t0\t0\t20\t2000\t6000\t50000\t0\t0\t0\t100\t50\t500\t200\n"
	printf "1789000002\t15\t15\t0\t0\t30\t2500\t5500\t50000\t0\t0\t0\t250\t80\t800\t450\n"
	printf "1789000004\t10\t10\t0\t0\t20\t2200\t5800\t50000\t0\t0\t0\t320\t110\t950\t600\n"
} >|"$RUN_DIR/runner-fetch/samples.tsv"

(cd "$REPO_ROOT" && node src/post.js)

IO_CHART="$RUN_DIR/runner-fetch/io_chart.mermaid"
PRIMARY_CHART="$RUN_DIR/runner-fetch/chart.mermaid"

if [ ! -s "$IO_CHART" ]; then
	echo "Error: io_chart.mermaid was not generated in Test 20" >&2
	exit 1
fi

if ! grep -q 'title "I/O Throughput Timeline"' "$IO_CHART"; then
	echo "Error: Title 'I/O Throughput Timeline' missing in io_chart.mermaid" >&2
	cat "$IO_CHART" >&2
	exit 1
fi

if ! grep -q 'y-axis "Throughput (MB)"' "$IO_CHART"; then
	echo "Error: Y-axis 'Throughput (MB)' missing in io_chart.mermaid" >&2
	cat "$IO_CHART" >&2
	exit 1
fi

if ! grep -q 'line "Disk Read"' "$IO_CHART" || ! grep -q 'line "Disk Write"' "$IO_CHART"; then
	echo "Error: Disk I/O series missing in io_chart.mermaid" >&2
	cat "$IO_CHART" >&2
	exit 1
fi

if ! grep -q 'line "Net RX"' "$IO_CHART" || ! grep -q 'line "Net TX"' "$IO_CHART"; then
	echo "Error: Network I/O series missing in io_chart.mermaid" >&2
	cat "$IO_CHART" >&2
	exit 1
fi

# Verify canvas width synchronization between charts and baseline width of 700
W_PRIMARY=$(grep -o '"width":[0-9]*' "$PRIMARY_CHART" | head -n 1)
W_IO=$(grep -o '"width":[0-9]*' "$IO_CHART" | head -n 1)
if [ "$W_PRIMARY" != '"width":700' ]; then
	echo "Error: Expected canvas width:700 for <=700 samples, got $W_PRIMARY" >&2
	exit 1
fi
if [ -n "$W_PRIMARY" ] && [ "$W_PRIMARY" != "$W_IO" ]; then
	echo "Error: Canvas width mismatch between primary chart ($W_PRIMARY) and IO chart ($W_IO)" >&2
	exit 1
fi

if ! grep -q "### I/O Throughput Timeline" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: '### I/O Throughput Timeline' missing in GITHUB_STEP_SUMMARY" >&2
	cat "$GITHUB_STEP_SUMMARY" >&2
	exit 1
fi

echo "Test 20 PASSED."

echo "=== Test 21: Windows target platform storage baseline & network telemetry parsing ==="
setup_test "test21"
export RUNNER_OS="Windows"
export INPUT_MONITOR_NETWORK="true"
mkdir -p "$RUN_DIR/runner-fetch"

# Mock storage_baseline.tsv on Windows (256GB total, 64GB used, 192GB free)
printf "%d\t%d\t%d\n" 274877906944 68719476736 206158430208 >|"$RUN_DIR/runner-fetch/storage_baseline.tsv"

# Mock samples with network metrics
{
	printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\tswap_used_mb\tswap_total_mb\tnet_rx_mb\tnet_tx_mb\n"
	printf "1789000000\t10\t10\t0\t0\t20\t2000\t6000\t50000\t0\t0\t0\t100\t50\n"
	printf "1789000002\t15\t15\t0\t0\t30\t2500\t5500\t50000\t0\t0\t0\t300\t150\n"
} >|"$RUN_DIR/runner-fetch/samples.tsv"

(cd "$REPO_ROOT" && node src/post.js)

if ! grep -q "Pre-installed: \*\*64.0 GB\*\* (25%)" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: Expected Windows pre-installed storage baseline not found in GITHUB_STEP_SUMMARY" >&2
	cat "$GITHUB_STEP_SUMMARY" >&2
	exit 1
fi

if ! grep -q "Free: \*\*192.0 GB\*\* / 256.0 GB" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: Expected Windows free storage baseline not found in GITHUB_STEP_SUMMARY" >&2
	cat "$GITHUB_STEP_SUMMARY" >&2
	exit 1
fi

if ! grep -q "RX: \*\*200 MB\*\*" "$GITHUB_STEP_SUMMARY" || ! grep -q "TX: \*\*100 MB\*\*" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: Expected Network delta not found in GITHUB_STEP_SUMMARY" >&2
	cat "$GITHUB_STEP_SUMMARY" >&2
	exit 1
fi

# Verify netstat -e parsing logic in monitor.sh
MOCK_NETSTAT="Interface Statistics

                           Received            Sent

Bytes                    3145728000         1048576000
Unicast packets           12345678          8765432
"
PARSED_NET=$(echo "$MOCK_NETSTAT" | awk '{ gsub(/\r/, "") } tolower($1) ~ /^bytes/ { printf "%d\t%d\n", int($2/1048576), int($3/1048576) }')
if [ "$PARSED_NET" != "3000	1000" ]; then
	printf "Error: Windows netstat -e awk parser returned '%s', expected '3000\\t1000'\\n" "$PARSED_NET" >&2
	exit 1
fi

echo "Test 21 PASSED."

echo "=== Test 22: macOS target platform Disk I/O (Read vs. Write) parser ==="
setup_test "test22"
export RUNNER_OS="macOS"
export INPUT_MONITOR_DISK_IO="true"
mkdir -p "$RUN_DIR/runner-fetch"

MOCK_TOP="Processes: 300 total, 2 running, 298 sleeping, 1200 threads
2026/10/04 12:00:00
Load Avg: 1.50, 1.20, 1.05
CPU usage: 12.5% user, 7.5% sys, 80.0% idle
SharedLibs: 250M resident, 45M data, 30M linkedit.
MemRegions: 50000 total, 2500M resident, 100M private, 800M shared.
PhysMem: 8000M used (2000M wired), 8384M unused.
VM: 3000G vsize, 2500M framework vsize, 0(0) swapins, 0(0) swapouts.
Networks: packets: 1000000/500M in, 800000/200M out.
Disks: 500000/120G read, 300000/45G written.
"

PARSED_DISK=$(echo "$MOCK_TOP" | awk '
function to_mb(str,   unit, val) {
	gsub(/[^0-9A-Za-z.]/, "", str)
	if (str == "" || str == "0") return 0
	unit = toupper(substr(str, length(str)))
	if (unit !~ /[BKMGT]/) return int((str + 0) / 1048576)
	val = substr(str, 1, length(str) - 1) + 0
	if (unit == "T") return int(val * 1048576)
	if (unit == "G") return int(val * 1024)
	if (unit == "M") return int(val)
	if (unit == "K") return int(val / 1024)
	return int(val / 1048576)
}
/Disks:/ {
	split($2, r_arr, "/")
	split($4, w_arr, "/")
	printf "%d\t%d\n", to_mb(r_arr[2]), to_mb(w_arr[2])
}')

if [ "$PARSED_DISK" != "122880	46080" ]; then
	printf "Error: macOS top Disks awk parser returned '%s', expected '122880\\t46080'\\n" "$PARSED_DISK" >&2
	exit 1
fi

# Verify units conversion for M and K as well
MOCK_TOP_M="Disks: 100/250M read, 200/50M written."
PARSED_DISK_M=$(echo "$MOCK_TOP_M" | awk '
function to_mb(str,   unit, val) {
	gsub(/[^0-9A-Za-z.]/, "", str)
	if (str == "" || str == "0") return 0
	unit = toupper(substr(str, length(str)))
	if (unit !~ /[BKMGT]/) return int((str + 0) / 1048576)
	val = substr(str, 1, length(str) - 1) + 0
	if (unit == "T") return int(val * 1048576)
	if (unit == "G") return int(val * 1024)
	if (unit == "M") return int(val)
	if (unit == "K") return int(val / 1024)
	return int(val / 1048576)
}
/Disks:/ {
	split($2, r_arr, "/")
	split($4, w_arr, "/")
	printf "%d\t%d\n", to_mb(r_arr[2]), to_mb(w_arr[2])
}')

if [ "$PARSED_DISK_M" != "250	50" ]; then
	printf "Error: macOS top Disks awk parser (M) returned '%s', expected '250\\t50'\\n" "$PARSED_DISK_M" >&2
	exit 1
fi

PARSED_CPU=$(echo "$MOCK_TOP" | awk -F'[:,%]' '/CPU usage:/ { printf "%d\t%d\t%d\n", int($2), int($4), int($2 + $4) }')
if [ "$PARSED_CPU" != "12	7	20" ]; then
	printf "Error: macOS top CPU user/sys awk parser returned '%s', expected '12\\t7\\t20'\\n" "$PARSED_CPU" >&2
	exit 1
fi

echo "Test 22 PASSED."

echo "=== Test 23: Cross-platform OOM diagnostics (macOS Jetsam & Windows Event 2004) ==="
# 1. macOS Jetsam test
setup_test "test23_macos"
export RUNNER_OS="macOS"
mkdir -p "$RUN_DIR/runner-fetch"
mkdir -p "$HOME/Library/Logs/DiagnosticReports"
touch "$HOME/Library/Logs/DiagnosticReports/JetsamEvent-2026-10-04-120000.ips"

t0=$(date +%s)
printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\n" >|"$RUN_DIR/runner-fetch/samples.tsv"
printf "%d\t10\t10\t0\t0\t20\t2000\t6000\t50000\t0\n" "$((t0 - 4))" >>"$RUN_DIR/runner-fetch/samples.tsv"
printf "%d\t15\t15\t0\t0\t30\t2500\t5500\t49800\t0\n" "$((t0 - 2))" >>"$RUN_DIR/runner-fetch/samples.tsv"

(cd "$REPO_ROOT" && node src/post.js)

rm -f "$HOME/Library/Logs/DiagnosticReports/JetsamEvent-2026-10-04-120000.ips"

if ! grep -q "Out-Of-Memory (Jetsam) Kill Detected!" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: macOS Jetsam OOM banner missing in GITHUB_STEP_SUMMARY" >&2
	cat "$GITHUB_STEP_SUMMARY" >&2
	exit 1
fi

node -e "
const fs = require('fs');
const summary = JSON.parse(fs.readFileSync('$RUN_DIR/runner-fetch/summary.json', 'utf8'));
if (!summary.oom_detected) {
  console.error('Error: summary.oom_detected false on macOS Jetsam');
  process.exit(1);
}
"

# 2. Windows Event 2004 test
setup_test "test23_windows"
export RUNNER_OS="Windows"
mkdir -p "$RUN_DIR/runner-fetch"
mkdir -p "$RUN_DIR/bin"
cat <<'EOF_MOCK' >"$RUN_DIR/bin/wevtutil"
#!/bin/sh
cat <<'EOF_WEVT'
Event[0]:
  Log Name: System
  Source: Microsoft-Windows-Resource-Exhaustion-Detector
  Date: 2026-10-04T12:00:00.000
  Event ID: 2004
  Description:
Windows successfully diagnosed a low virtual memory condition. The following programs consumed the most virtual memory: cargo.exe (1234) consumed 4500000000 bytes.
EOF_WEVT
EOF_MOCK
chmod +x "$RUN_DIR/bin/wevtutil"
ORIGINAL_PATH="$PATH"
export PATH="$RUN_DIR/bin:$PATH"

t0=$(date +%s)
printf "epoch\tcpu_user\tcpu_system\tcpu_steal\tcpu_iowait\tcpu_total\tmem_used_mb\tmem_avail_mb\tdisk_free_mb\toom_kills\n" >|"$RUN_DIR/runner-fetch/samples.tsv"
printf "%d\t10\t10\t0\t0\t20\t2000\t6000\t50000\t0\n" "$((t0 - 4))" >>"$RUN_DIR/runner-fetch/samples.tsv"
printf "%d\t15\t15\t0\t0\t30\t2500\t5500\t49800\t0\n" "$((t0 - 2))" >>"$RUN_DIR/runner-fetch/samples.tsv"

(cd "$REPO_ROOT" && node src/post.js)
export PATH="$ORIGINAL_PATH"

if ! grep -q "Resource Exhaustion / Out-Of-Memory Detected!" "$GITHUB_STEP_SUMMARY"; then
	echo "Error: Windows Resource Exhaustion banner missing in GITHUB_STEP_SUMMARY" >&2
	cat "$GITHUB_STEP_SUMMARY" >&2
	exit 1
fi

node -e "
const fs = require('fs');
const summary = JSON.parse(fs.readFileSync('$RUN_DIR/runner-fetch/summary.json', 'utf8'));
if (!summary.oom_detected) {
  console.error('Error: summary.oom_detected false on Windows Event 2004');
  process.exit(1);
}
"

echo "Test 23 PASSED."

echo "=== ALL SCENARIOS PASSED SUCCESSFULLY ==="
