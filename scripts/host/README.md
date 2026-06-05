# Host-level CI substrate defenses (bluesea)

These run on the bluesea **host** (not in containers — they must keep working
when /data is 100% full or docker itself is wedged). Synced from the live host
2026-06-05; this directory is the source of truth going forward.

| file | install path | cadence | role |
|---|---|---|---|
| `ci-watchdog.sh` | `/usr/local/bin/` | cron */15 | self-heal + SendGrid alert (Jenkins offline, agent dead, disk pressure, SonarQube ES read-only) |
| `ci-disk-gc.sh` | `/usr/local/bin/` | cron */20 | age-based (>6h) `*:build-N` image GC + stale `arcana-ci-*` test-container reaper |
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
