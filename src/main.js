import './env.js';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const rootDir = path.join(process.env.RUNNER_TEMP || '/tmp', 'runner-fetch');
const rootInitDoneFile = path.join(rootDir, 'init_done');
const hasRootInit = fs.existsSync(rootInitDoneFile);

const phaseStartInput = (process.env.INPUT_PHASE_START || '').trim();
const phaseEndInput = (process.env.INPUT_PHASE_END || '').trim();
const milestoneInput = (process.env.INPUT_MILESTONE || '').trim();
const isPhaseStep = Boolean(phaseStartInput || phaseEndInput || milestoneInput);

const activeScopesFile = path.join(rootDir, 'active_scopes.json');
const readActiveScopes = () => {
  try { return JSON.parse(fs.readFileSync(activeScopesFile, 'utf8')); } catch { return []; }
};
const writeActiveScopes = (s) => fs.writeFileSync(activeScopesFile, JSON.stringify(s), 'utf8');

// Determine execution scope:
const isRootJob = !hasRootInit && !isPhaseStep;

let outDir = rootDir;
if (!isRootJob) {
  const phaseIdentifier = phaseStartInput || phaseEndInput || milestoneInput || 'scoped';
  const phaseSlug = phaseIdentifier.toLowerCase().replace(/[^a-z0-9_-]/g, '_');
  outDir = path.join(rootDir, 'scopes', phaseSlug);
}

process.env.RUNNER_FETCH_DIR = outDir;
process.env.RUNNER_FETCH_ROOT_DIR = rootDir;

const pidFile = path.join(outDir, 'monitor.pid');
const monitorScript = path.join(import.meta.dirname, 'monitor.sh');
const fetchScript = path.join(import.meta.dirname, 'fetch.sh');
const phaseScript = path.join(import.meta.dirname, 'phase.sh');
const summaryScript = path.join(import.meta.dirname, 'summary.sh');

fs.mkdirSync(outDir, { recursive: true });

const initDoneFile = path.join(outDir, 'init_done');
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

  // If this is a scoped action completing its phase, trigger summary and teardown immediately
  if (!isRootJob && phaseEndInput) {
    const summaryResult = spawnSync('sh', [summaryScript], {
      stdio: 'inherit',
      env: process.env,
    });
    // Pop this phase from active scopes stack upon completion
    const active = readActiveScopes();
    const phaseSlug = phaseEndInput.toLowerCase().replace(/[^a-z0-9_-]/g, '_');
    writeActiveScopes(active.filter(s => s.slug !== phaseSlug));

    if (summaryResult.error) {
      console.error('Failed to run summary.sh:', summaryResult.error);
      process.exit(1);
    }
    process.exit(summaryResult.status !== null ? summaryResult.status : 0);
  }

  process.exit(result.status !== null ? result.status : 0);
}

if (!isRootJob && phaseStartInput) {
  const active = readActiveScopes();
  const parent = active.length > 0 ? active[active.length - 1].slug : null;
  const phaseSlug = phaseStartInput.toLowerCase().replace(/[^a-z0-9_-]/g, '_');
  fs.writeFileSync(path.join(outDir, 'meta.json'), JSON.stringify({
    name: phaseStartInput,
    slug: phaseSlug,
    parentSlug: parent
  }), 'utf8');
  active.push({ name: phaseStartInput, slug: phaseSlug });
  writeActiveScopes(active);
}

// Mark this invocation as the initialization step for this scope
fs.writeFileSync(initDoneFile, String(process.pid), 'utf8');
if (isRootJob && process.env.GITHUB_STATE) {
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

const enableMonitor =
  Object.keys(process.env).some(
    (k) => k.startsWith('INPUT_MONITOR_') && process.env[k] === 'true'
  ) ||
  process.env.INPUT_MONITOR_CPU !== 'false' ||
  process.env.INPUT_MONITOR_MEMORY !== 'false';

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

