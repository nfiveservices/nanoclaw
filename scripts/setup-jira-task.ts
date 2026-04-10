#!/usr/bin/env tsx
/**
 * Registers the Jira high-priority issue poller as a scheduled task
 * for the service-mgmt group. Run once:
 *
 *   npx tsx scripts/setup-jira-task.ts
 *
 * The task polls every 10 minutes. The pre-check script runs first and only
 * wakes the agent when new High or Highest priority issues are found —
 * no Claude API cost on empty polls.
 */

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const PROJECT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const IPC_TASKS_DIR = path.join(PROJECT_ROOT, 'data', 'ipc', 'service-mgmt', 'tasks');

const GROUP_JID = 'slack:C0ANXEF9FHT';
const GROUP_FOLDER = 'service-mgmt';

// Path to the pre-check script that runs on the host before the agent is woken.
// This file lives in the repo at a location not mounted into any container,
// so its contents cannot be modified by a container agent.
const SCRIPT_FILE = 'scripts/task-scripts/jira-poller.sh';

const agentPrompt = `New high-priority Jira issues have been found in project N5SM (provided in the task data above).

For each issue, follow the High-Priority Issue Workflow defined in your CLAUDE.md:
1. Resolve the assignee account ID for info@nfive.uk
2. Create a subtask with actionable instructions derived from the parent description
3. Assign the subtask to info@nfive.uk
4. Transition both the parent issue and the subtask to In Progress
5. Send a summary via send_message when done`;

function writeIpcFile(dir: string, data: object): void {
  fs.mkdirSync(dir, { recursive: true });
  const filename = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}.json`;
  const filepath = path.join(dir, filename);
  const tempPath = `${filepath}.tmp`;
  fs.writeFileSync(tempPath, JSON.stringify(data, null, 2));
  fs.renameSync(tempPath, filepath);
  console.log(`Written: ${filepath}`);
}

const task = {
  type: 'schedule_task',
  taskId: `task-jira-poller-${Date.now()}`,
  prompt: agentPrompt,
  script_file: SCRIPT_FILE,
  schedule_type: 'cron',
  schedule_value: '*/10 * * * *',
  context_mode: 'isolated',
  targetJid: GROUP_JID,
  createdBy: GROUP_FOLDER,
  timestamp: new Date().toISOString(),
};

writeIpcFile(IPC_TASKS_DIR, task);
console.log('Jira poller task registered. It will run every 10 minutes.');
console.log('The agent only wakes when new High/Highest priority issues are found in N5SM.');
