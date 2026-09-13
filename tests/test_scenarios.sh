#!/bin/sh
set -euC

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR="${RUNNER_TEMP:-/tmp}/test-runner-suite-$$"
mkdir -p "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM

echo "=== Test 1: Normal execution & telemetry generation ==="
RUN_DIR="$TEST_DIR/test1"
mkdir -p "$RUN_DIR"
export RUNNER_TEMP="$RUN_DIR"
export GITHUB_OUTPUT="$RUN_DIR/output.txt"
export GITHUB_STEP_SUMMARY="$RUN_DIR/summary.md"
export INPUT_DISK_TREE="false"
export INPUT_MONITOR="true"
export INPUT_SAMPLE_INTERVAL="1"
touch "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY"

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
RUN_DIR="$TEST_DIR/test2"
mkdir -p "$RUN_DIR"
export RUNNER_TEMP="$RUN_DIR"
export GITHUB_OUTPUT="$RUN_DIR/output.txt"
export GITHUB_STEP_SUMMARY="$RUN_DIR/summary.md"
touch "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY"

(cd "$REPO_ROOT" && node src/main.js)
# Simulate step failure / crash
(cd "$REPO_ROOT" && node src/post.js)

if [ ! -s "$RUN_DIR/runner-fetch/summary.json" ]; then
  echo "Error: summary.json was not generated on step failure in Test 2" >&2
  exit 1
fi
echo "Test 2 PASSED."

echo "=== Test 3: OOM kill detection & special character JSON escaping ==="
RUN_DIR="$TEST_DIR/test3"
mkdir -p "$RUN_DIR"
export RUNNER_TEMP="$RUN_DIR"
export GITHUB_OUTPUT="$RUN_DIR/output.txt"
export GITHUB_STEP_SUMMARY="$RUN_DIR/summary.md"
touch "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY"

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

echo "=== Test 4: monitor: false disabled cleanly without warnings ==="
RUN_DIR="$TEST_DIR/test4"
mkdir -p "$RUN_DIR"
export RUNNER_TEMP="$RUN_DIR"
export GITHUB_OUTPUT="$RUN_DIR/output.txt"
export GITHUB_STEP_SUMMARY="$RUN_DIR/summary.md"
export INPUT_MONITOR="false"
touch "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY"

(cd "$REPO_ROOT" && node src/main.js)
(cd "$REPO_ROOT" && node src/post.js)

if [ -s "$GITHUB_STEP_SUMMARY" ]; then
  echo "Error: Step summary should be empty when monitor: false" >&2
  exit 1
fi
echo "Test 4 PASSED."

echo "=== ALL SCENARIOS PASSED SUCCESSFULLY ==="
