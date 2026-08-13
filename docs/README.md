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
| `environment` | JSON containing OS, distro, kernel, architecture, hostname, runner name, and uptime. |
| `cpu` | JSON containing CPU model, cores, threads, and cache levels (`lscpu --json`). |
| `storage` | JSON containing block devices, partitions, filesystem formats, and free space (`lsblk --json`). |
| `hardware` | JSON containing hardware topology and RAM specs (`lshw -json`). |
| `disk_tree_path` | Path to JSON file containing full recursive filesystem tree with file and directory sizes (`dust -j`). |

## Examples

- **Linux (`ubuntu-latest`)**: https://github.com/Malix-Labs/GitHub-Action_Runner-Fetch/actions/workflows/fetch.yml?query=job%3Ainspect-runner+%28ubuntu-latest%29
- **macOS (`macos-latest`)**: https://github.com/Malix-Labs/GitHub-Action_Runner-Fetch/actions/workflows/fetch.yml?query=job%3Ainspect-runner+%28macos-latest%29
- **Windows (`windows-latest`)**: https://github.com/Malix-Labs/GitHub-Action_Runner-Fetch/actions/workflows/fetch.yml?query=job%3Ainspect-runner+%28windows-latest%29

