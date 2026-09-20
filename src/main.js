const { spawn, spawnSync } = require('child_process');
const path = require('path');

// Normalize RUNNER_TEMP to forward slashes across platforms (especially Windows)
if (process.env.RUNNER_TEMP) {
  process.env.RUNNER_TEMP = process.env.RUNNER_TEMP.replace(/\\/g, '/');
}

const monitorScript = path.join(__dirname, 'monitor.sh');
const fetchScript = path.join(__dirname, 'fetch.sh');

const enableMonitor = Object.keys(process.env).some(
  (k) => k.startsWith('INPUT_MONITOR_') && process.env[k] === 'true'
);

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
