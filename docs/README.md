# GitHub Action - Runner Fetch

GitHub Action to Fetch Information of its Runner

- System
- Hardware
- Storage topology
- Filesystem formats
- Complete directory trees
- Environment specifications

In JSON format

---

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

---

## Outputs

| Output | Description |
| :--- | :--- |
| `environment` | JSON containing OS, distro, kernel, architecture, hostname, runner name, and uptime. |
| `cpu` | JSON containing CPU model, cores, threads, and cache levels (`lscpu --json`). |
| `storage` | JSON containing block devices, partitions, filesystem formats, and free space (`lsblk --json`). |
| `hardware` | JSON containing hardware topology and RAM specs (`lshw -json`). |
| `disk_tree` | JSON containing full recursive filesystem tree with file and directory sizes (`ncdu -o - /`). |
