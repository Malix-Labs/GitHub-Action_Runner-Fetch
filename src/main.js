import './env.js';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const outDir = path.join(process.env.RUNNER_TEMP || '/tmp', 'runner-fetch');
const pidFile = path.join(outDir, 'monitor.pid');
const monitorScript = path.join(import.meta.dirname, 'monitor.sh');
const fetchScript = path.join(import.meta.dirname, 'fetch.sh');
const phaseScript = path.join(import.meta.dirname, 'phase.sh');

fs.mkdirSync(outDir, { recursive: true });

const initDoneFile = path.join(outDir, 'init_done');
const isPhaseStep = Boolean(
  (process.env.INPUT_PHASE_START && process.env.INPUT_PHASE_START.trim()) ||
    (process.env.INPUT_PHASE_END && process.env.INPUT_PHASE_END.trim()) ||
    (process.env.INPUT_MILESTONE && process.env.INPUT_MILESTONE.trim())
);

const isAlreadyInitialized = fs.existsSync(initDoneFile);

if (isAlreadyInitialized && isPhaseStep) {
  const result = spawnSync('sh', [phaseScript], {
    stdio: 'inherit',
    env: process.env,
  });
  if (result.error) {
    console.error('Failed to run phase.sh:', result.error);
    process.exit(1);
  }
  process.exit(result.status !== null ? result.status : 0);
}

// Mark this invocation as the primary initialization step
fs.writeFileSync(initDoneFile, String(process.pid), 'utf8');
if (process.env.GITHUB_STATE) {
  try {
    fs.appendFileSync(process.env.GITHUB_STATE, 'is_primary_init=true\n');
  } catch (err) {
    console.warn('Failed to write to GITHUB_STATE:', err.message);
  }
}

// If phase inputs were provided during the primary init step, execute phase marker
if (isPhaseStep) {
  spawnSync('sh', [phaseScript], {
    stdio: 'inherit',
    env: process.env,
  });
}

function isMonitorRunning() {
  try {
    if (!fs.existsSync(pidFile)) return false;
    const pidStr = fs.readFileSync(pidFile, 'utf8').trim();
    if (!pidStr) return false;
    const pid = Number.parseInt(pidStr, 10);
    if (!pid || Number.isNaN(pid)) return false;
    // Sending signal 0 tests whether the process exists and is running
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

const enableMonitor = Object.keys(process.env).some(
  (k) => k.startsWith('INPUT_MONITOR_') && process.env[k] === 'true'
);

if (enableMonitor && !isMonitorRunning()) {
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

