import './env.js';
import { spawnSync } from 'node:child_process';
import path from 'node:path';

const summaryScript = path.join(import.meta.dirname, 'summary.sh');
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
