# v1 fork customizations → v2 mapping

This install was migrated from a customized NanoClaw **v1** fork
(`nfiveservices/nanoclaw`) to **v2.0.64** on 2026-05-29. The v1 checkout is
preserved read-only at `../nanoclaw` (and `store/messages.db` there is the
authoritative v1 source). This note records how each v1 customization maps onto
v2 so nothing is silently lost. v1 `src/*` is **not** ported — v2's architecture
is fundamentally different — it's documented here instead.

## Custom Slack channel
- **v1**: `src/channels/slack.ts` (~390 lines, hand-written `@slack/bolt` Socket
  Mode client, 4000-char chunking, health-check/reconnect, user-name cache) +
  `slack.test.ts`.
- **v2**: replaced by the Chat SDK Slack adapter (`@chat-adapter/slack@4.26.0`)
  via the `/add-slack` channel skill. Chunking → `splitForLimit()` in
  `src/channels/chat-sdk-bridge.ts` (paragraph-aware). Reconnect → bridge
  exponential backoff. No custom code retained.
- **Transport change (Socket Mode → HTTP Events).** v1 ran Slack in **Socket
  Mode** (`SLACK_APP_TOKEN` xapp-, outbound WebSocket, no public URL).
  `@chat-adapter/slack@4.26.0` has **no Socket Mode** — its config only accepts
  `botToken`/`signingSecret` (verified: zero websocket/app-token code in the
  package). So v2 uses **HTTP Events API**: the shared webhook server
  (`src/webhook-server.ts`) listens on `0.0.0.0:3000` at path `/webhook/slack`,
  exposed publicly via an **ngrok reserved domain**
  (`unrecurrently-theosophic-kingston.ngrok-free.dev`) run as a systemd user
  service `ngrok-nanoclaw.service` (forwards :3000; linger enabled so it
  survives reboot). `.env` needs `SLACK_SIGNING_SECRET` (Slack app → Basic
  Information). `SLACK_APP_TOKEN` is now unused but left in `.env`. Slack app
  config: Event Subscriptions Request URL =
  `https://<domain>/webhook/slack`, bot events `app_mention`,
  `message.channels/groups/im/mpim`. Chosen over re-porting a Socket Mode
  adapter to avoid a permanent fork divergence in the channel layer (keeps
  `/update-nanoclaw` conflict-free).

## Jira service-management integration
- **v1**: `scripts/setup-jira-task.ts` registered a cron task; the host ran
  `scripts/task-scripts/jira-poller.sh` as a pre-check (`script_file`) via
  `runScriptOnHost()` in `src/task-scheduler.ts`, gated by `wakeAgent`. Trust
  boundary enforced by `validateScriptFile()` in `src/ipc.ts`. The agent read
  `$JIRA_USERNAME`/`$JIRA_API_TOKEN` from container env and used Basic auth.
- **v2**:
  - The poller is now `scripts/jira-poller.sh`, set as the **`script`** field on
    the recurring `kind='task'` row (id `task-jira-poller-1775827045968`,
    recurrence `*/10 * * * *`) in the service-mgmt session `inbound.db`. v2's
    agent-runner runs it in-container before each tick and skips the Claude turn
    when `wakeAgent=false` (`container/agent-runner/src/scheduling/task-script.ts`).
  - Jira auth is injected by the **OneCLI gateway** (generic secret "Jira N5SM",
    host `nfive.atlassian.net`, `Authorization: Basic …`). The script and the
    agent use `curl` with no auth header; the raw token stays in the vault.
  - Workflow instructions live in `groups/service-mgmt/CLAUDE.local.md`.
  - v1's host-side `script_file`/`runScriptOnHost`/`validateScriptFile` plumbing
    is obsolete — v2 has no host↔container IPC; tasks are session-DB rows.

## Notes
- v1 `is_main=1` (service-mgmt) → v2 `user_roles(owner)` (seeded at first message).
- v1 `requires_trigger=0` → v2 `engage_mode='pattern'`, `engage_pattern='.'`.
- Chat history (`messages`/`chats`), `router_state`, and v1 `sessions` were not
  migrated by design — they remain in `../nanoclaw/store/messages.db`.
