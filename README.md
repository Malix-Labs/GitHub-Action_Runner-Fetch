# GitHub Action - Runner Fetch

GitHub Action to inspect and continuously monitor GitHub Actions runner VMs.

- Environment, OS distribution, kernel, architecture, packages, and toolcache
- Hardware topology and CPU specifications
- Storage topology, partitions, filesystem formats, and free space
- Recursive directory tree via `dust`
- Continuous resource saturation monitoring (CPU %, RAM, Disk)
- Automatic crash / Out-Of-Memory (OOM) autopsy diagnostics
- Dual-consumption: formatted Markdown and SVG sparklines in
  `$GITHUB_STEP_SUMMARY` for humans, structured JSON and OpenMetrics
  (`metrics.prom`) for machines

## Usage

```yaml
steps:
  - name: Fetch & Monitor Runner
    id: fetch
    uses: Malix-Labs/GitHub-Action_Runner-Fetch@v2
    with:
      monitor: true
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

## Inputs

| Input | Description | Default |
| :--- | :--- | :--- |
| `monitor` | Enable continuous background resource monitoring | `true` |
| `disk-tree` | Build recursive directory tree via `dust` | `true` |
| `sample-interval` | Sampling interval in seconds | `2` |
| `export-prometheus` | Generate OpenMetrics / Prometheus file | `true` |

## Outputs

| Output | Description |
| :--- | :--- |
| `environment` | JSON containing OS, distro, kernel, architecture, hostname, runner name, and uptime |
| `cpu` | JSON containing CPU model, cores, threads, and cache levels |
| `storage` | JSON containing block devices, partitions, filesystem formats, and free space |
| `hardware` | JSON containing hardware topology and RAM specs |
| `disk_tree_path` | Path to JSON file containing full recursive filesystem tree (`dust -j`) |
| `artifact_name` | Deterministic name of the disk tree artifact |
| `summary` | JSON containing aggregate utilization metrics and autopsy data |
| `peak_memory_mb` | Peak RAM usage in megabytes observed during the job |
| `avg_cpu_percent` | Average CPU utilization percentage across the job |
| `disk_consumed_mb` | Net disk space consumed in megabytes |
| `oom_detected` | Boolean indicating whether a Linux kernel OOM kill occurred |

## Why is Node 24 used instead of a pure composite action?

GitHub Actions does not support `post:` hooks for composite actions
([actions/runner#1478](https://github.com/actions/runner/issues/1478)).

Without a post step, users would be forced to manually add an extra teardown
step with `if: always()` at the bottom of every workflow. To keep your
workflows clean (one step only), we use a minimal 10-line Node 24 wrapper
strictly to hook into GitHub's runner lifecycle. All fetching, sampling, and
reporting logic remains 100% shell scripts.

Please [upvote the upstream issue](https://github.com/actions/runner/issues/1478)
if you want native composite post-step support!

## Examples

See workflow runs in action:
[Fetch & Monitor Workflows](https://github.com/Malix-Labs/GitHub-Action_Runner-Fetch/actions/workflows/fetch.yml)
