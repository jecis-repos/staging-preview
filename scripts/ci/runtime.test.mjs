import { test } from 'node:test';
import assert from 'node:assert/strict';
import { configureRuntime } from './runtime.mjs';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test('rejects an unset workspace before loading provisioning tools', () => {
  assert.throws(() => configureRuntime({}), /STAGING_PREVIEW_BASE_DIR/);
});
test('maps the documented staging settings to the backend', () => {
  const env = { STAGING_PREVIEW_BASE_DIR: '/tmp/preview-example', STAGING_PREVIEW_DOMAIN: 'preview.example.com', STAGING_PREVIEW_CADDY_MANAGED_TLS: 'true' };
  configureRuntime(env);
  assert.equal(env.DEVMACHINE_BASE_DIR, '/tmp/preview-example');
  assert.equal(env.DEVMACHINE_DOMAIN_SUFFIX, 'preview.example.com');
  assert.equal(env.DEVMACHINE_CADDY_MANAGED_TLS, 'true');
  assert.equal(env.DEVMACHINE_DISABLE_HOSTS_UPDATE, 'true');
});
test('bundled backend loads without provisioning and uses the configured registry', () => {
  const workspace = mkdtempSync(join(tmpdir(), 'staging-runtime-'));
  try {
    const output = execFileSync(process.execPath, ['--input-type=module', '-e', `
      import { loadRuntime } from './scripts/ci/runtime.mjs';
      const r = await loadRuntime();
      console.log(JSON.stringify({registry: r.registryPath, types: [typeof r.createInstance, typeof r.removeInstanceTool, typeof r.updateInstance]}));
    `], { env: { ...process.env, STAGING_PREVIEW_BASE_DIR: workspace }, encoding: 'utf8' });
    const result = JSON.parse(output);
    assert.equal(result.registry, join(workspace, 'mcp-server', 'registry.json'));
    assert.deepEqual(result.types, ['function', 'function', 'function']);
  } finally { rmSync(workspace, { recursive: true, force: true }); }
});
