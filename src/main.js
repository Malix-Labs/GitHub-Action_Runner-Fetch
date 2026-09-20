const { spawn, spawnSync } = require('child_process');
const path = require('path');

// Normalize RUNNER_TEMP to forward slashes across platforms (especially Windows)
if (process.env.RUNNER_TEMP) {
  process.env.RUNNER_TEMP = process.env.RUNNER_TEMP.replace(/\\/g, '/');
}

const monitorScript = path.join(__dirname, 'monitor.sh');
const fetchScript = path.join(__dirname, 'fetch.sh');

const enableCpu = process.env.INPUT_MONITOR_CPU !== 'false';
const enableMem = process.env.INPUT_MONITOR_MEMORY !== 'false';
const enableDisk = process.env.INPUT_MONITOR_DISK === 'true';
const enableNetwork = process.env.INPUT_MONITOR_NETWORK === 'true';
const enableDiskIo = process.env.INPUT_MONITOR_DISK_IO === 'true';
const enableSwap = process.env.INPUT_MONITOR_SWAP === 'true';
const enableGpu = process.env.INPUT_MONITOR_GPU === 'true';

const enableMonitor = enableCpu || enableMem || enableDisk || enableNetwork || enableDiskIo || enableSwap || enableGpu;

if (enableMonitor) {
  try {
    const monitorProc = spawn('sh', [monitorScript], {
      detached: true,
      stdio: 'ignore',
      env: process.env,
    });
    monitorProc.unref();
  } catch (err) {
    console.warn('Failed to start monitor daemon:', err.message);
  }
}

const result = spawnSync('sh', [fetchScript], {
  stdio: 'inherit',
  env: process.env,
});

if (result.error) {
  console.error('Failed to start fetch.sh:', result.error);
  process.exit(1);
}

process.exit(result.status !== null ? result.status : 1);

