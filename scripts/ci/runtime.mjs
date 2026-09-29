import { resolve } from 'node:path';

// Set the backend environment before importing its configuration singleton.
export function configureRuntime(env = process.env) {
  const baseDir = env.STAGING_PREVIEW_BASE_DIR?.trim();
  if (!baseDir) throw new Error('STAGING_PREVIEW_BASE_DIR must point to the prepared application workspace');
  env.DEVMACHINE_BASE_DIR = resolve(baseDir);
  const mapping = {
    DOMAIN: 'DOMAIN_SUFFIX', DISABLE_HOSTS_UPDATE: 'DISABLE_HOSTS_UPDATE',
    CADDY_MANAGED_TLS: 'CADDY_MANAGED_TLS', CERT_PATH: 'CERT_PATH',
    CERT_KEY_PATH: 'CERT_KEY_PATH', CADDY_CERT_PATH: 'CADDY_CERT_PATH',
    CADDY_CERT_KEY_PATH: 'CADDY_CERT_KEY_PATH', PHP_IMAGE: 'PHP_IMAGE',
    NETWORK: 'NETWORK', COMPOSE_PROJECT: 'COMPOSE_PROJECT', PROJECT_SUBDIR: 'PROJECT_SUBDIR',
  };
  for (const [source, target] of Object.entries(mapping)) {
    const value = env[`STAGING_PREVIEW_${source}`]?.trim();
    if (value) env[`DEVMACHINE_${target}`] = value;
  }
  env.DEVMACHINE_DISABLE_HOSTS_UPDATE ??= 'true';
  return env.DEVMACHINE_BASE_DIR;
}

export async function loadRuntime() {
  configureRuntime();
  const [create, remove, update, config] = await Promise.all([
    import('../../mcp-server/dist/tools/create-instance.js'),
    import('../../mcp-server/dist/tools/remove-instance.js'),
    import('../../mcp-server/dist/tools/update-instance.js'),
    import('../../mcp-server/dist/config.js'),
  ]);
  return { createInstance: create.createInstance, removeInstanceTool: remove.removeInstanceTool,
    updateInstance: update.updateInstance, registryPath: config.REGISTRY_PATH };
}
