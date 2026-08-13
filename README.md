# GitHub Action - Runner Fetch

GitHub Action to Fetch Information of its Runner

- System
- Hardware
- Storage topology
- Filesystem formats
- Complete directory trees
- Environment specifications

In JSON format

## Usage

```yaml
steps:
  - name: Inspect Runner Environment
    id: fetch
    uses: Malix-Labs/GitHub-Action_Runner-Fetch@v1

  - name: Process Storage Output
    run: |
      echo '${{ steps.fetch.outputs.storage }}' | jq '.blockdevices[] | select(.mountpoint == "/")'
```

## Outputs

| Output | Description |
| :--- | :--- |
| `environment` | JSON containing OS, distro (`os_name`, `os_version`, `os_codename`), kernel, architecture, hostname, runner name, uptime, toolcache, and packages inventory. |
| `cpu` | JSON containing CPU model, cores, threads, and cache levels (`lscpu --json` / `sysctl` / `Win32_Processor`). |
| `storage` | JSON containing block devices, partitions, filesystem formats, and free space (`lsblk -b -O --json` / `diskutil` / `Get-Volume`). |
| `hardware` | JSON containing hardware topology and RAM specs (`lshw -json` / `system_profiler` / `Win32_ComputerSystem`). |
| `disk_tree_path` | Path to JSON file containing full recursive filesystem tree with file and directory sizes (`dust -j`). |

## Examples

https://github.com/Malix-Labs/GitHub-Action_Runner-Fetch/actions/workflows/fetch.yml

