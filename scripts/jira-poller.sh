#!/usr/bin/env bash
# Jira high-priority issue pre-check — v2 / OneCLI gateway edition.
#
# Runs INSIDE the service-mgmt agent container as the task-script gate
# (container/agent-runner/src/scheduling/task-script.ts). The agent-runner
# executes it with `bash` before each recurring run; if the last stdout line
# is {"wakeAgent":false} the expensive Claude turn is skipped (cost guard).
#
# HTTP goes through `curl` so the OneCLI gateway injects the Jira
# Authorization header (generic secret, host nfive.atlassian.net). No raw
# token lives in the container — do NOT add an Authorization header here.
#
# Output contract: a single JSON line on stdout:
#   {"wakeAgent": true|false, "data": { "issues": [...] }}
# Fail-closed: any error → {"wakeAgent": false} (never a false wake).
set -uo pipefail

export JIRA_BASE="https://nfive.atlassian.net"

node --input-type=module <<'EOF'
import { execFileSync } from 'node:child_process';

const BASE = process.env.JIRA_BASE;
// Trust the gateway's MITM CA if the runtime exposes it to curl.
const caArgs = process.env.NODE_EXTRA_CA_CERTS ? ['--cacert', process.env.NODE_EXTRA_CA_CERTS] : [];

function jiraGet(path) {
  const out = execFileSync(
    'curl',
    ['-fsS', ...caArgs, '-H', 'Accept: application/json', `${BASE}${path}`],
    { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 },
  );
  return JSON.parse(out);
}

let sd;
try {
  sd = jiraGet('/rest/servicedeskapi/request?requestStatus=OPEN_REQUESTS&maxResults=50');
} catch (err) {
  process.stderr.write(`service desk fetch failed: ${err.message}\n`);
  console.log(JSON.stringify({ wakeAgent: false }));
  process.exit(0);
}

const HIGH_PRIORITY_IDS = ['1', '2']; // Highest=1, High=2
const getField = (issue, id) => (issue.requestFieldValues || []).find((f) => f.fieldId === id)?.value ?? null;

const highPriority = (sd.values || []).filter((i) => {
  const p = getField(i, 'priority');
  const pid = p?.id ?? p;
  return HIGH_PRIORITY_IDS.includes(String(pid));
});

if (highPriority.length === 0) {
  console.log(JSON.stringify({ wakeAgent: false }));
  process.exit(0);
}

// Skip issues that already have subtasks — the workflow has already run.
const newIssues = [];
for (const issue of highPriority) {
  let detail;
  try {
    detail = jiraGet(`/rest/api/3/issue/${issue.issueKey}?fields=subtasks,summary,description,priority`);
  } catch (err) {
    process.stderr.write(`issue ${issue.issueKey} fetch failed: ${err.message}\n`);
    continue;
  }
  if ((detail.fields?.subtasks ?? []).length > 0) {
    process.stderr.write(`skipping ${issue.issueKey}: already has subtask(s)\n`);
    continue;
  }
  newIssues.push({
    key: issue.issueKey,
    summary: detail.fields?.summary ?? getField(issue, 'summary'),
    description: detail.fields?.description ?? getField(issue, 'description'),
    priority: detail.fields?.priority?.name ?? null,
  });
}

console.log(JSON.stringify({ wakeAgent: newIssues.length > 0, data: { issues: newIssues } }));
EOF
