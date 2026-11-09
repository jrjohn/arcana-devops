# bluesea agent files under version control

These files run on bluesea but used to exist **only** there (no git history). They are kept
here so a rebuild of the host does not lose them and every change has a commit.

| Repo path | Live path on bluesea | What it is |
|---|---|---|
| `daily-ci-agent/prompts/daily.md` | `/data/projects/daily-ci-agent/prompts/daily.md` (bind-mounted read-only into the `daily-ci-agent` container) | The daily CI remediation agent's instructions (09:00 run) |
| `claude-agents-workflow/weekly-rebuild-agent.sh` | `/data/projects/claude-agents-workflow/weekly-rebuild-agent.sh` (rocky crontab, Sunday 04:00) | Rebuilds `daily-ci-agent` and `agent-task-node` with the latest Claude CLI, rolling back on failure |

**Deploy a change:** edit here, merge, then copy to the live path, e.g.

```bash
scp agents/daily-ci-agent/prompts/daily.md bluesea:/tmp/daily.md && \
  ssh bluesea 'sudo cp -p /data/projects/daily-ci-agent/prompts/daily.md{,.bak-$(date +%m%d%H%M)} && sudo install -m 644 /tmp/daily.md /data/projects/daily-ci-agent/prompts/daily.md'
```

No secrets belong in these files: tokens are read from environment variables at run time.
