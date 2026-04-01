#!/usr/bin/env node

import { readFileSync, appendFileSync } from 'fs';
import { sanitizeSlug, extractTaskToken } from './preview-naming.mjs';

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

function writeOutput(key, value) {
  const outputPath = process.env.GITHUB_OUTPUT;
  if (!outputPath) {
    throw new Error('Missing GITHUB_OUTPUT');
  }
  appendFileSync(outputPath, `${key}=${value}\n`, 'utf-8');
}

const eventPath = required('GITHUB_EVENT_PATH');
const domainSuffix = process.env.STAGING_PREVIEW_DOMAIN?.trim() || 'preview.example.com';
const raw = readFileSync(eventPath, 'utf-8');
const event = JSON.parse(raw);
const pull = event?.pull_request;

if (!pull) {
  throw new Error('This workflow expects pull_request event payload.');
}

const action = String(event?.action || '').trim();
const prNumber = Number(pull?.number);
const branch = String(pull?.head?.ref || '').trim();
const base = String(pull?.base?.ref || '').trim();
const labels = Array.isArray(pull?.labels) ? pull.labels.map((l) => String(l?.name || '').trim()) : [];

if (!Number.isFinite(prNumber) || prNumber <= 0) {
  throw new Error('Invalid pull request number in event payload.');
}
if (!branch) {
  throw new Error('Missing pull request head branch in event payload.');
}

const taskToken = extractTaskToken(branch, prNumber);
console.log(`token=${taskToken} branch=${branch}`);

let taskSlug = sanitizeSlug(taskToken);
if (!taskSlug) {
  taskSlug = `pr${prNumber}`;
}

const maxPrefixLength = 32;
const instanceName = taskSlug.slice(0, maxPrefixLength);

// Determine DB seed from labels (defaults to 'default')
let dbSeed = 'default';
for (const label of labels) {
  const normalized = label.toLowerCase();
  const seedMatch = normalized.match(/^db:(.+)$/);
  if (seedMatch) {
    dbSeed = seedMatch[1];
  }
}

const skipStaging = labels.some((l) => l.toLowerCase() === 'skip-staging');
const mode = action === 'closed' ? 'destroy' : skipStaging ? 'skip' : 'provision';
const displayName = `PR #${prNumber} ${taskToken}`.slice(0, 80);
const previewHost = `${instanceName}.${domainSuffix}`;

writeOutput('preview_mode', mode);
writeOutput('instance_name', instanceName);
writeOutput('branch_name', branch);
writeOutput('db_seed', dbSeed);
writeOutput('display_name', displayName);
writeOutput('preview_host', previewHost);
writeOutput('pr_number', String(prNumber));
writeOutput('base_branch', base);
writeOutput('task_token', taskToken);

console.log(`mode=${mode}`);
console.log(`instance=${instanceName}`);
console.log(`host=${previewHost}`);
console.log(`db_seed=${dbSeed}`);
