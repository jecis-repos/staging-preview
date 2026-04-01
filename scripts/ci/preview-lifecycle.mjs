#!/usr/bin/env node

import { createInstance } from '../../mcp-server/dist/tools/create-instance.js';
import { removeInstanceTool } from '../../mcp-server/dist/tools/remove-instance.js';
import { updateInstance } from '../../mcp-server/dist/tools/update-instance.js';
import { hasError } from './preview-naming.mjs';

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

function hasRecoverableProvisionConflict(logOutput, instanceName) {
  const patterns = [
    /Target directory already exists at /i,
    /Caddy block .* already exists/i,
    /Service ".*-app" already exists in docker-compose\.yml/i,
    /already exists in docker-compose\.yml/i,
    new RegExp(`Instance with prefix "${instanceName}" already exists`, 'i'),
  ];
  return patterns.some((pattern) => pattern.test(logOutput));
}

async function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function healthCheck(instanceName, domainSuffix) {
  const url = `https://${instanceName}.${domainSuffix}`;
  const maxRetries = 10;
  const delayMs = 5000;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      const response = await fetch(url, {
        redirect: 'manual',
        signal: AbortSignal.timeout(5000),
      });
      const code = response.status;

      if (code >= 200 && code < 400) {
        console.log(`Health check passed: ${url} -> ${code} (attempt ${attempt}/${maxRetries})`);
        return true;
      }

      console.log(`Health check attempt ${attempt}/${maxRetries}: ${url} -> ${code}`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.log(`Health check attempt ${attempt}/${maxRetries}: ${url} -> ${msg}`);
    }

    if (attempt < maxRetries) {
      await sleep(delayMs);
    }
  }

  console.log(`WARNING: Health check failed after ${maxRetries} attempts for ${url}`);
  return false;
}

async function run() {
  const mode = required('PREVIEW_MODE');
  const name = required('INSTANCE_NAME');

  let output = '';

  if (mode === 'provision') {
    const branch = required('BRANCH_NAME');
    const displayName = process.env.DISPLAY_NAME?.trim() || `Preview ${name}`;
    const timezone = process.env.TIMEZONE?.trim() || 'UTC';
    const dbSeed = process.env.DB_SEED?.trim() || 'default';
    const ttlHours = parseInt(process.env.PREVIEW_TTL_HOURS || '0', 10) || undefined;

    output = await createInstance({
      branch,
      name,
      display_name: displayName,
      timezone,
      db_seed: dbSeed,
      ttl_hours: ttlHours,
    });

    // If instance already exists, update in-place (preserves database)
    if (hasError(output) && hasRecoverableProvisionConflict(output, name)) {
      process.stdout.write(
        `Instance "${name}" already exists. Attempting in-place update.\n`,
      );
      output = await updateInstance({ name, branch });

      // If update also fails, fall back to destroy + re-provision
      if (hasError(output)) {
        process.stdout.write(
          `In-place update failed for "${name}". Falling back to destroy + re-provision.\n`,
        );
        const cleanupOutput = await removeInstanceTool({
          name,
          keep_database: false,
          keep_files: false,
        });
        process.stdout.write(`${cleanupOutput}\n`);

        output = await createInstance({
          branch,
          name,
          display_name: displayName,
          timezone,
          db_seed: dbSeed,
          ttl_hours: ttlHours,
        });
      }
    }
  } else if (mode === 'destroy') {
    output = await removeInstanceTool({ name, keep_database: false, keep_files: false });
  } else {
    throw new Error(`Unsupported PREVIEW_MODE: ${mode}`);
  }

  process.stdout.write(`${output}\n`);

  if (!hasError(output)) {
    // Post-provision/update health check (warning-only)
    if (mode === 'provision') {
      const domainSuffix = process.env.STAGING_PREVIEW_DOMAIN?.trim() || 'preview.example.com';
      await healthCheck(name, domainSuffix);
    }
    return;
  }

  if (mode === 'destroy' && /not found in registry/i.test(output)) {
    process.stdout.write(`No-op: instance "${name}" was already absent.\n`);
    return;
  }

  throw new Error(`${mode} failed for instance "${name}"`);
}

run().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
