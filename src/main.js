const { spawnSync } = require('child_process');
const path = require('path');

const fetchScript = path.join(__dirname, 'fetch.sh');
const result = spawnSync('sh', [fetchScript], {
  stdio: 'inherit',
  env: process.env,
});

if (result.error) {
  console.error('Failed to start fetch.sh:', result.error);
  process.exit(1);
}

process.exit(result.status !== null ? result.status : 1);
