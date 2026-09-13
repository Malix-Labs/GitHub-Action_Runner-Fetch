const { spawnSync } = require('child_process');
const path = require('path');

const summaryScript = path.join(__dirname, 'summary.sh');
const result = spawnSync('sh', [summaryScript], {
  stdio: 'inherit',
  env: process.env,
});

if (result.error) {
  console.error('Failed to start summary.sh:', result.error);
  process.exit(1);
}

process.exit(result.status !== null ? result.status : 1);
