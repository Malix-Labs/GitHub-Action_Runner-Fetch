// Normalize RUNNER_TEMP to forward slashes across platforms (especially Windows)
if (process.env.RUNNER_TEMP) {
  process.env.RUNNER_TEMP = process.env.RUNNER_TEMP.replace(/\\/g, '/');
}

// Normalize GitHub Action input environment variables (hyphen to underscore)
for (const [key, value] of Object.entries(process.env)) {
  if (key.startsWith('INPUT_')) {
    const normalizedKey = key.replace(/-/g, '_');
    if (!(normalizedKey in process.env)) {
      process.env[normalizedKey] = value;
    }
  }
}
