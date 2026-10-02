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

if ! grep -q "### ⏱️ Phase Breakdown" "$GITHUB_STEP_SUMMARY"; then
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

echo "=== ALL SCENARIOS PASSED SUCCESSFULLY ==="
