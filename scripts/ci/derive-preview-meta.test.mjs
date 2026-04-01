#!/usr/bin/env node

/**
 * Tests for extractTaskToken() and sanitizeSlug() used in CI preview naming.
 * Run with: node --test scripts/ci/derive-preview-meta.test.mjs
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

function sanitizeSlug(value) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, '');
}

function extractTaskToken(branch, prNumber) {
  // Matches project-code style tokens: 2-10 letters, dash/underscore, then digits
  const taskMatch = branch.match(/\b([A-Za-z]{2,10})[_-](\d+)(?!\.\d)\b/);
  if (taskMatch) {
    return `${taskMatch[1]}${taskMatch[2]}`.toLowerCase();
  }
  return `pr${prNumber}`;
}

describe('extractTaskToken', () => {
  it('extracts task code from feature/PROJ-XXX/description pattern', () => {
    assert.equal(extractTaskToken('feature/PROJ-123/add-validation', 99), 'proj123');
    assert.equal(extractTaskToken('feature/TASK-678/general_task_management_module', 99), 'task678');
    assert.equal(extractTaskToken('feature/TEAM-665/propose_ui_ux_architecture', 99), 'team665');
  });

  it('extracts task code from bugfix/PROJ-XXX/description pattern', () => {
    assert.equal(extractTaskToken('bugfix/PROJ-456/fix-button', 99), 'proj456');
  });

  it('extracts task code with dash separator', () => {
    assert.equal(extractTaskToken('fix/PROJ-789-penalty-permission', 99), 'proj789');
  });

  it('is case insensitive', () => {
    assert.equal(extractTaskToken('feature/PROJ-100/foo', 99), 'proj100');
    assert.equal(extractTaskToken('feature/proj-100/foo', 99), 'proj100');
    assert.equal(extractTaskToken('feature/Proj-100/foo', 99), 'proj100');
  });

  it('falls back to pr<number> when no task code', () => {
    assert.equal(extractTaskToken('fix/add-write-off-penalty-permission', 235), 'pr235');
    assert.equal(extractTaskToken('fix/staging-wipe-hardening', 222), 'pr222');
    assert.equal(extractTaskToken('dependabot/npm_and_yarn/laravel-echo-2.3.0', 234), 'pr234');
    assert.equal(extractTaskToken('main', 100), 'pr100');
  });

  it('takes the first task code match when multiple exist', () => {
    assert.equal(extractTaskToken('feature/PROJ-123-updates-PROJ-456', 99), 'proj123');
  });
});

describe('sanitizeSlug', () => {
  it('lowercases and strips non-alphanumeric characters', () => {
    assert.equal(sanitizeSlug('PROJ-123'), 'proj123');
    assert.equal(sanitizeSlug('task456'), 'task456');
    assert.equal(sanitizeSlug('pr99'), 'pr99');
  });

  it('returns empty string for non-alphanumeric input', () => {
    assert.equal(sanitizeSlug('---'), '');
  });
});
