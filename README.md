# GitHub Action - Runner Fetch

GitHub Action to inspect and continuously monitor GitHub Actions runner VMs.

- Environment, OS distribution, kernel, architecture, packages, and toolcache
- Hardware topology and CPU specifications
- Storage topology, partitions, filesystem formats, and free space
- Recursive directory tree via `dust`
- Continuous resource saturation monitoring (CPU %, RAM, Disk, Network, I/O, Swap, GPU)
- Automatic crash / Out-Of-Memory (OOM) autopsy diagnostics
- Dual-consumption: formatted Markdown, Unicode sparklines, and native Mermaid timeline chart in `$GITHUB_STEP_SUMMARY` for humans, structured JSON and OpenMetrics (`metrics.prom`) for machines

## Features & Highlights

- **Multi-Call Phase Tracking & Milestone Profiling**: Mark execution phases using `phase-start` / `phase-end` or pin instantaneous point events using `milestone`. The action automatically aggregates per-phase metrics, captures telemetry snapshots at milestones, and outputs a consolidated comparison table in `$GITHUB_STEP_SUMMARY`.
- **Synchronized Companion Gantt Chart**: Generates an aligned Mermaid Gantt chart placed alongside the resource timeline, rendering phases as duration intervals and milestones as markers with matched dynamic canvas widths.
- **Automated Runner Start-Time Alignment**: Auto-detects runner initialization time from the environment, automatically offsetting the Mermaid timeline X-axis (e.g. `45s --> 120s`) when the action is called late in a workflow run.
- **Storage Baseline & Pre-installed Bloat Reporting**: Automatically captures initial disk partition capacity, pre-installed software bloat, and net consumption in `$GITHUB_STEP_SUMMARY`.
- **Phase Breakdown Table**: Automatically renders a dedicated comparison table contrasting each phase's and milestone's resource profile against the total job.
- **Dedicated I/O Throughput Timeline**: Renders a dedicated Mermaid line chart tracking disk throughput (Read/Write MB) and network transfer (RX/TX MB) over elapsed time whenever `monitor-disk-io` or `monitor-network` is enabled.
- **Cross-Platform Out-Of-Memory (OOM) Autopsy**: Automatic crash inspection detects memory exhaustion across Linux (cgroup v2 & `vmstat`), macOS (Jetsam and DiagnosticReports), and Windows (Resource-Exhaustion-Detector Event ID 2004), placing a high-visibility cautionary advisory in the step summary.
- **Dynamic Mermaid Budgeting**: Dynamically downsamples high-density metrics using peak-preserving bucketing to stay strictly within Mermaid's 50,000 character ceiling while maintaining exact spike fidelity.

## Usage

### Basic Usage

```yaml
steps:
  - name: Fetch & Monitor Runner
    id: fetch
    uses: Malix-Labs/GitHub-Action_Runner-Fetch@v1.0.0
    with:
      monitor-cpu: true
      monitor-memory: true
      monitor-disk: false
      disk-tree: true
      sample-interval: 2
      export-prometheus: true

  - name: Your Real CI Workload
    run: |
      echo "Running build and test steps..."
      cargo build --release

  - name: Inspect Runner Telemetry
    if: always()
    run: |
      echo "Peak Memory: ${{ steps.fetch.outputs.peak_memory_mb }} MB"
      echo "Avg CPU: ${{ steps.fetch.outputs.avg_cpu_percent }}%"
      echo "OOM Detected: ${{ steps.fetch.outputs.oom_detected }}"
```

### Multi-Call Phase Tracking & Milestone Profiling

You can mark execution phases using `phase-start` and `phase-end`, or pin instantaneous point events using `milestone`. The action automatically aggregates per-phase metrics, captures telemetry snapshots at milestones, and outputs a consolidated Phase Breakdown comparison table alongside a companion Mermaid Gantt chart in `$GITHUB_STEP_SUMMARY`:

```yaml
steps:
  # Initial step initializes monitoring and starts the Setup phase
  - name: Init Telemetry & Start Setup
    uses: Malix-Labs/GitHub-Action_Runner-Fetch@v1.0.0
    with:
      phase-start: "Setup"

  - name: Restore cache
    run: npm ci

  # Mark an instantaneous milestone
  - name: Milestone Cache Restored
    id: milestone-cache
    uses: Malix-Labs/GitHub-Action_Runner-Fetch@v1.0.0
    with:
      milestone: "Cache Restored"

  # Transition from Setup to Build phase
  - name: End Setup & Start Build
    id: phase-build
    uses: Malix-Labs/GitHub-Action_Runner-Fetch@v1.0.0
    with:
      phase-end: "Setup"
      phase-start: "Build"

  - name: Build workload
    run: npm run build

  # Complete Build phase
  - name: End Build
    uses: Malix-Labs/GitHub-Action_Runner-Fetch@v1.0.0
    with:
      phase-end: "Build"
```

## Inputs

| Input | Description | Default |
| :--- | :--- | :--- |
| `monitor-cpu` | Monitor CPU utilization percentage and performance | `true` |
| `monitor-memory` | Monitor memory (RAM) usage and kernel OOM events | `true` |
| `monitor-disk` | Monitor disk space consumption and net disk delta | `false` |
| `monitor-network` | Monitor network I/O throughput (RX/TX bytes) | `false` |
| `monitor-disk-io` | Monitor disk I/O throughput and read/write rates | `false` |
| `monitor-swap` | Monitor swap space usage and paging | `false` |
| `monitor-gpu` | Monitor GPU utilization and VRAM (auto-detects `nvidia-smi`) | `false` |
| `sample-interval` | Telemetry sampling interval in seconds | `2` |
| `export-prometheus` | Generate standard OpenMetrics / Prometheus (`metrics.prom`) | `true` |
| `phase-start` | Mark the beginning of a named execution phase | `""` |
| `phase-end` | Mark the completion of a named execution phase | `""` |
| `milestone` | Record an instantaneous workflow milestone or point event | `""` |
| `disk-tree` | Build recursive directory tree via `dust` | `true` |

## Outputs

| Output | Description |
| :--- | :--- |
| `environment` | JSON containing OS, distro, kernel, architecture, hostname, runner name, and uptime |
| `cpu` | JSON containing CPU model, cores, threads, and cache levels |
| `storage` | JSON containing block devices, partitions, filesystem formats, total and free space |
| `hardware` | JSON containing hardware topology and RAM specs |
| `disk_tree_path` | Path to JSON file containing full recursive filesystem tree (`dust -j`) |
| `artifact_name` | Deterministic name of the disk tree artifact |
| `summary` | JSON containing aggregate utilization metrics, storage baseline, phases, milestones, and autopsy data |
| `peak_memory_mb` | Peak RAM usage in megabytes observed during the job |
| `avg_cpu_percent` | Average CPU utilization percentage across the job |
| `disk_consumed_mb` | Net disk space consumed in megabytes |
| `oom_detected` | Boolean indicating whether a kernel Out-Of-Memory (OOM) or resource exhaustion kill occurred across Linux, macOS, or Windows |
| `phase_name` | Name of the ended phase |
| `phase_duration_seconds` | Duration of the phase in seconds |
| `phase_peak_memory_mb` | Peak RAM usage in megabytes during the phase |
| `phase_avg_cpu_percent` | Average CPU utilization percentage during the phase |
| `phase_disk_consumed_mb` | Net disk space consumed in megabytes during the phase |
| `milestone_name` | Name of the recorded milestone |
| `milestone_timestamp` | Unix epoch timestamp of the milestone |
| `milestone_memory_mb` | RAM usage in megabytes at the milestone |
| `milestone_cpu_percent` | CPU utilization percentage at the milestone |
| `milestone_disk_free_mb` | Free disk space in megabytes at the milestone |
| `peak_swap_mb` | Peak swap usage in megabytes observed during the job |
| `network_rx_mb` | Total network data received in megabytes during the job |
| `network_tx_mb` | Total network data transmitted in megabytes during the job |
| `disk_read_mb` | Total disk data read in megabytes during the job |
| `disk_write_mb` | Total disk data written in megabytes during the job |
| `peak_gpu_percent` | Peak GPU core utilization percentage during the job |
| `peak_vram_mb` | Peak GPU VRAM usage in megabytes during the job |
| `summary_table` | Markdown table summarizing runner resource baseline, peak, and final metrics |
| `summary_markdown` | Complete rendered Markdown telemetry report including tables, duration, and notices |
| `resource_chart_mermaid` | Mermaid source code for the Resource Utilization Timeline XY chart |
| `io_chart_mermaid` | Mermaid source code for the I/O Throughput Timeline XY chart |
| `gantt_mermaid` | Mermaid source code for the Workflow Phases and Milestones Gantt chart |

## Accessing Telemetry Data

### In-Workflow Consumption

Downstream steps in the same job can read discrete Markdown tables, full Markdown reports, or Mermaid diagram strings directly from step outputs:

```yaml
- name: Post Performance Comment to Pull Request
  if: always()
  uses: actions/github-script@v7
  with:
    script: |
      const table = `${{ steps.fetch.outputs.summary_table }}`;
      const chart = `${{ steps.fetch.outputs.resource_chart_mermaid }}`;
      github.rest.issues.createComment({
        issue_number: context.issue.number,
        owner: context.repo.owner,
        repo: context.repo.repo,
        body: `### Runner Telemetry\n\n${table}\n\n${chart}`
      });
```

### Asynchronous CLI and API Access

The action emits structured log groups to stdout, allowing automated tools and the GitHub CLI to extract the Markdown table or Mermaid diagrams directly from job logs after the workflow completes, without downloading zip artifacts:

```bash
# Extract the Markdown table
gh run view <run-id> --log | awk '/::group::runner_fetch_summary_table/{f=1;next} /::endgroup::/{f=0} f' > table.md

# Extract the Resource Utilization Timeline Mermaid diagram
gh run view <run-id> --log | awk '/::group::runner_fetch_resource_chart_mermaid/{f=1;next} /::endgroup::/{f=0} f' > resource_chart.mmd

# Extract the complete rendered Markdown report
gh run view <run-id> --log | awk '/::group::runner_fetch_summary_markdown/{f=1;next} /::endgroup::/{f=0} f' > report.md
```

## Why is Node 24 used instead of a pure composite action?

GitHub Actions does not support `post:` hooks for composite actions ([actions/runner#1478](https://github.com/actions/runner/issues/1478)).

Without a post step, users would be forced to manually add an extra teardown step with `if: always()` at the bottom of every workflow. To keep your workflows clean (one step only), we use a minimal 10-line Node 24 wrapper strictly to hook into GitHub's runner lifecycle. All fetching, sampling, and reporting logic remains 100% shell scripts.

Please [upvote the upstream issue](https://github.com/actions/runner/issues/1478) if you want native composite post-step support!

## Examples

See workflow runs in action:
[Fetch & Monitor Workflows](https://github.com/Malix-Labs/GitHub-Action_Runner-Fetch/actions/workflows/fetch.yml)
