#!/usr/bin/env node

import { readFile } from 'fs/promises';
import { removeInstanceTool } from '../../mcp-server/dist/tools/remove-instance.js';
import { sanitizeSlug, extractTaskToken, deriveTaskInstanceName, hasError } from './preview-naming.mjs';

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

async function listOpenPullRequests(owner, repo, token) {
  const openPrs = [];
  let page = 1;

  while (true) {
    const url = `https://api.github.com/repos/${owner}/${repo}/pulls?state=open&per_page=100&page=${page}`;
    const response = await fetch(url, {
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
      },
    });

    if (!response.ok) {
      throw new Error(`GitHub API error ${response.status}: ${await response.text()}`);
    }

    const items = await response.json();
    if (!Array.isArray(items) || items.length === 0) {
      break;
    }

    for (const pr of items) {
      if (typeof pr?.number === 'number') {
        openPrs.push({
          number: pr.number,
          branch: String(pr?.head?.ref || '').trim(),
        });
      }
    }

    const linkHeader = response.headers.get('link');
    if (!linkHeader || !linkHeader.includes('rel="next"')) {
      break;
    }

    page += 1;
  }

  return openPrs;
}

function isPreviewInstance(instance) {
  const displayName = String(instance?.display_name ?? '').trim();
  return /^PR #\d+\b/i.test(displayName);
}

async function run() {
  const repo = required('GITHUB_REPOSITORY');
  const token = required('GITHUB_TOKEN');
  const [owner, repoName] = repo.split('/');

  if (!owner || !repoName) {
    throw new Error(`Invalid GITHUB_REPOSITORY: ${repo}`);
  }

  const openPrs = await listOpenPullRequests(owner, repoName, token);
  const activePreviewPrefixes = new Set(
    openPrs
      .filter((pr) => Number.isFinite(pr.number) && pr.number > 0 && pr.branch)
      .map((pr) => deriveTaskInstanceName(pr.branch, pr.number)),
  );
  let instances = [];
  try {
    const registryRaw = await readFile('mcp-server/registry.json', 'utf-8');
    const registry = JSON.parse(registryRaw);
    instances = Array.isArray(registry?.instances) ? registry.instances : [];
  } catch {
    console.log('No registry.json found or invalid JSON — nothing to reconcile.');
    return;
  }

  const previewInstances = instances.filter((inst) => isPreviewInstance(inst));

  if (previewInstances.length === 0) {
    console.log('No preview instances to reconcile.');
    return;
  }

  for (const inst of previewInstances) {
    const prefix = String(inst.prefix);
    const displayName = String(inst.display_name ?? '').trim();

    if (activePreviewPrefixes.has(prefix)) {
      console.log(`Keeping ${prefix}: active task preview (${displayName}).`);
      continue;
    }

    console.log(`Removing orphan preview ${prefix}: no active PR maps to this task (${displayName}).`);
    const output = await removeInstanceTool({ name: prefix, keep_database: false, keep_files: false });
    process.stdout.write(`${output}\n`);

    if (hasError(output) && !/not found in registry/i.test(output)) {
      throw new Error(`Failed removing orphan preview ${prefix}`);
    }
  }
}

run().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
