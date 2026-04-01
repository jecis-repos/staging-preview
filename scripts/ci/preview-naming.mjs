/**
 * Shared naming utilities for staging preview CI scripts.
 * Used by derive-preview-meta.mjs, reconcile-previews.mjs, and preview-lifecycle.mjs.
 */

export function sanitizeSlug(value) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, '');
}

export function extractTaskToken(branch, prNumber) {
  // Extract a task identifier from the branch name.
  // Matches project-code style tokens: 2-10 uppercase/lowercase letters, a dash or
  // underscore, then 1+ digits. Examples: PROJ-123, TASK-456, TEAM_789.
  // Customize the pattern below to match your project's branch naming convention.
  // Default: falls back to pr<number>
  const taskMatch = branch.match(/\b([A-Za-z]{2,10})[_-](\d+)(?!\.\d)\b/);
  if (taskMatch) {
    return `${taskMatch[1]}${taskMatch[2]}`.toLowerCase();
  }
  return `pr${prNumber}`;
}

export function deriveTaskInstanceName(branch, prNumber) {
  const taskToken = extractTaskToken(branch, prNumber);
  const taskSlug = sanitizeSlug(taskToken) || `pr${prNumber}`;
  return taskSlug.slice(0, 32);
}

export function hasError(logOutput) {
  return /(^|\n)ERROR:/.test(logOutput);
}
