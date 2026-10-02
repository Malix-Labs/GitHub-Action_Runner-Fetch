import './env.js';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const outDir = path.join(process.env.RUNNER_TEMP || '/tmp', 'runner-fetch');
const summaryDoneFile = path.join(outDir, 'summary_done');

// In GitHub Actions, only the primary init step should run the consolidated summary
if (process.env.GITHUB_STATE) {
  if (process.env.STATE_is_primary_init !== 'true') {
    process.exit(0);
  }
} else {
  // If running locally or in tests where GITHUB_STATE is absent:
  if (fs.existsSync(summaryDoneFile)) {
    process.exit(0);
  }
  fs.writeFileSync(summaryDoneFile, 'true', 'utf8');
}

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

