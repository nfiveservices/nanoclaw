#!/usr/bin/env bash
# Jira high-priority issue pre-check.
# Runs on the host before the agent container is spawned.
# Reads JIRA_BASE_URL, JIRA_USERNAME, JIRA_API_TOKEN from the environment
# (injected by the task scheduler from .env — never passed to containers).
# Outputs a single JSON line: { "wakeAgent": true|false, "data": {...} }
# Exit 0 required; any non-zero exit suppresses the agent.

node --input-type=module << 'EOF'
const baseUrl = process.env.JIRA_BASE_URL;
const username = process.env.JIRA_USERNAME;
const apiToken = process.env.JIRA_API_TOKEN;

if (!baseUrl || !username || !apiToken) {
  process.stderr.write('Missing JIRA_BASE_URL, JIRA_USERNAME, or JIRA_API_TOKEN env vars\n');
  console.log(JSON.stringify({ wakeAgent: false }));
  process.exit(0);
}

const auth = Buffer.from(`${username}:${apiToken}`).toString('base64');
const headers = { 'Authorization': `Basic ${auth}`, 'Accept': 'application/json' };

async function jiraGet(path) {
  const response = await fetch(`${baseUrl}${path}`, { headers });
  const data = await response.json();
  if (!response.ok) {
    throw new Error(`Jira API error ${response.status}: ${JSON.stringify(data)}`);
  }
  return data;
}

// Fetch open high-priority requests from the Service Desk API
let sdData;
try {
  sdData = await jiraGet('/rest/servicedeskapi/request?requestStatus=OPEN_REQUESTS&maxResults=50');
} catch (err) {
  process.stderr.write(`Failed to fetch service desk requests: ${err.message}\n`);
  console.log(JSON.stringify({ wakeAgent: false }));
  process.exit(0);
}

function getField(issue, fieldId) {
  const field = (issue.requestFieldValues || []).find(f => f.fieldId === fieldId);
  return field?.value ?? null;
}

const HIGH_PRIORITY_IDS = ['1', '2']; // Highest=1, High=2

const highPriorityIssues = (sdData.values || []).filter(i => {
  const priority = getField(i, 'priority');
  const priorityId = priority?.id ?? priority;
  return HIGH_PRIORITY_IDS.includes(String(priorityId));
});

if (highPriorityIssues.length === 0) {
  console.log(JSON.stringify({ wakeAgent: false }));
  process.exit(0);
}

// For each high-priority issue, check if it already has subtasks via the
// standard Jira REST API. If subtasks exist, this workflow has already run —
// skip the issue to prevent duplicate subtasks piling up on unresolved tickets.
const newIssues = [];
for (const issue of highPriorityIssues) {
  let issueDetail;
  try {
    issueDetail = await jiraGet(`/rest/api/3/issue/${issue.issueKey}?fields=subtasks,summary,description,priority`);
  } catch (err) {
    process.stderr.write(`Failed to fetch issue ${issue.issueKey}: ${err.message}\n`);
    continue;
  }

  const subtasks = issueDetail.fields?.subtasks ?? [];
  if (subtasks.length > 0) {
    process.stderr.write(`Skipping ${issue.issueKey}: already has ${subtasks.length} subtask(s)\n`);
    continue;
  }

  newIssues.push({
    key: issue.issueKey,
    summary: issueDetail.fields?.summary ?? getField(issue, 'summary'),
    description: issueDetail.fields?.description ?? getField(issue, 'description'),
    priority: issueDetail.fields?.priority?.name ?? getField(issue, 'priority')?.name ?? getField(issue, 'priority'),
  });
}

if (newIssues.length === 0) {
  console.log(JSON.stringify({ wakeAgent: false }));
  process.exit(0);
}

console.log(JSON.stringify({ wakeAgent: true, data: { issues: newIssues } }));
EOF
