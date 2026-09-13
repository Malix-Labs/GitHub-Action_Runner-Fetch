const { spawnSync } = require('child_process');
const path = require('path');

// Normalize RUNNER_TEMP to forward slashes across platforms (especially Windows)
if (process.env.RUNNER_TEMP) {
  process.env.RUNNER_TEMP = process.env.RUNNER_TEMP.replace(/\\/g, '/');
}

const summaryScript = path.join(__dirname, 'summary.sh');
const result = spawnSync('sh', [summaryScript], {
  stdio: 'inherit',
  env: process.env,
});

if (result.error) {
  console.error('Failed to start summary.sh:', result.error);
} else if (result.status !== 0) {
  console.error(`summary.sh exited with code ${result.status}`);
}

process.exit(0);
