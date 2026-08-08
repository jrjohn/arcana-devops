# Host-level CI substrate defenses (bluesea)

These run on the bluesea **host** (not in containers — they must keep working
when /data is 100% full or docker itself is wedged). Synced from the live host
2026-06-05; this directory is the source of truth going forward.

| file | install path | cadence | role |
|---|---|---|---|
| `ci-watchdog.sh` | `/usr/local/bin/` | cron */15 | self-heal + SendGrid alert (Jenkins offline, agent dead, disk pressure, SonarQube ES read-only) |
| `ci-disk-gc.sh` | `/usr/local/bin/` | cron */20 | age-based (>6h) `*:build-N` image GC + stale `arcana-ci-*` test-container reaper + idle CI network reaper |
| `ci-remediate.sh` | `/usr/local/bin/` | on demand (watchdog) | remediation actions: prune-disk, online-builtin, restart-sonarqube, … |
| `cron.d/*` | `/etc/cron.d/` | — | cron definitions for the above |

Install/update:

```bash
sudo cp scripts/host/ci-*.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/ci-*.sh
sudo cp scripts/host/cron.d/* /etc/cron.d/
```

## Disk-pressure defense layers (post 2026-06-04 incident)

`/data` filling to 100% corrupts docker network state (kafka lost its endpoint
→ workflow Data Index froze → zombie RUNNING instances). Layers, inner to outer:

1. **ci-disk-gc** (*/20 min): removes `*:build-N` images older than 6 h — age,
   not count, is the safe criterion (multibranch jobs share one tag space, so
   keep-N-highest deleted in-progress PR builds).
2. **docker-cleanup.sh** (03:00 daily, `scripts/`): registry tag GC + blob GC +
   `image prune -a --filter until=6h` + builder/volume prune.
3. **ci-watchdog** (*/15 min): at ≥88 % runs `ci-remediate.sh prune-disk`; at
   ≥95 % **pre-prune** sends a SendGrid alert immediately (added 2026-06-05 —
   the old post-prune-only condition stayed silent through three 100 % spikes).

These buy time; they do not add capacity. Sustained build-storm peaks reaching
~96 % mean /data needs to grow.

## Jenkins job seeding (resurrection trap)

`init/create-jobs.groovy` re-imports every `jobs/*.xml` at **every Jenkins
boot** (creates any job that doesn't exist). Therefore:

- deleting a job in the UI is NOT durable — also delete its `jobs/*.xml` (both
  in this repo and in the deployed `/data/devops/jobs/`), or it resurrects on
  the next restart (2026-06-04: a stale deployed jobs dir resurrected all 15
  retired legacy single-branch pipelines).
- `jobs/` here holds only the 14 active `-mb` multibranch seeds; keep the
  deployed dir in sync with it.

Retired legacy seeds live on the host at `/data/devops/jobs-retired-20260605/`.

## CI network address-pool defense (2026-08-08 incident)

Each multibranch/compose build creates a network that grabs a **full /16**, and
Docker's default pool is only `172.17.0.0/16`–`172.31.0.0/16` (~15 nets). Idle
per-branch/`arcana-ci-*` nets that leak on aborted runs accumulate until the pool
is exhausted — a build then dies at `docker compose build` with
`all predefined address pools have been fully subnetted` (node-app PR-102 held a
release a full day; code + deps were fine, proven by a local build).

Fix lives in **`ci-disk-gc.sh`** as an *age-based* reaper (>2h, 0-container,
CI-named nets only) — **not** a blanket `docker network prune -f`, which races
in-flight compose builds (2026-05-29 killed rust main #11). The old
"idle nets are metadata-only" assumption was wrong: they cost address-pool space,
not disk. Optional robustness (needs a `dockerd` restart): set
`default-address-pools` with `size: 24` in `daemon.json` so each net takes a /24
(256 per /16) instead of a /16.
