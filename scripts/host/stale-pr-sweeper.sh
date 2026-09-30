#!/bin/bash
# stale-pr-sweeper — safety net for PRs that stop moving without anyone noticing.
#
# Why (2026-09-30): three PRs sat for days with nothing wrong in their code:
#   * arcana-ios #13     — every check green, but ABORTED by the pipeline-wide timeout because it
#                          queued ~1h for built-in executors during the Renovate wave (6 days).
#   * arcana-android #109 — release PR green since 2026-09-26, merge-flow never started: the
#                          ci-bpmn-trigger POST for that build was lost, and nothing re-sends it (4 days).
#   * node #150 / react #131 — failed on "no space left on device" while /data was full (1 day).
# ci-flow deliberately ignores ABORTED builds and only handles FAILURE, and merge-flow only starts
# from the one POST at build completion, so each of these was a dead end.
#
# What it does (hourly, for every open PR branch whose last build finished > STALE_HOURS ago and is
# neither building nor queued):
#   * SUCCESS              -> re-send the same merge-flow start ci-bpmn-trigger sends
#   * ABORTED by timeout   -> rebuild
#   * FAILURE, disk full   -> rebuild
#   * anything else        -> left to ci-flow
# Each PR gets ONE automatic nudge per build. If the next check finds it stuck again, it opens one
# issue in jrjohn/arcana-devops ("[stale-pr] ...") and stops acting on it. Issues close themselves
# once the PR is merged or closed.
#
# SWEEP_DRY=1 prints what it would do without doing it.
set -u
STATE=${STATE:-/data/projects/claude-agents-workflow/stale-pr-sweeper.state.json}
LOG=${LOG:-/data/projects/claude-agents-workflow/stale-pr-sweeper.log}
export STATE SWEEP_DRY=${SWEEP_DRY:-0} STALE_HOURS=${STALE_HOURS:-6}
export JC="$(sudo cat /etc/ci-jenkins-cred 2>/dev/null)"
[ -n "$JC" ] || { echo "$(date '+%F %T') no Jenkins credential, skipping" >> "$LOG"; exit 0; }

python3 - <<'PYEOF' 2>&1 | while IFS= read -r l; do echo "$(date '+%F %T') $l"; done >> "$LOG"
import base64, json, os, re, subprocess, time, urllib.request, urllib.error, xml.etree.ElementTree as ET

J = "http://localhost:8080/jenkins"
DRY = os.environ["SWEEP_DRY"] == "1"
STALE_MS = float(os.environ["STALE_HOURS"]) * 3600 * 1000
AUTH = "Basic " + base64.b64encode(os.environ["JC"].encode()).decode()
ISSUE_REPO = "jrjohn/arcana-devops"
MARK = "[stale-pr]"
now = time.time() * 1000

def http(path, method="GET", data=None, headers=None, raw=False):
    req = urllib.request.Request(J + path, data=data, method=method)
    req.add_header("Authorization", AUTH)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read().decode("utf-8", "replace")
        return body if raw else (json.loads(body) if body.strip() else {})

def crumb():
    c = http("/crumbIssuer/api/json")
    return {c["crumbRequestField"]: c["crumb"]}

def gh(*args):
    r = subprocess.run(["docker", "exec", "agent-task-node", "gh", *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None

def act(desc, fn):
    """Run one action; a failure is logged and returns False so the sweep goes on with the next PR."""
    print(("DRY: " if DRY else "") + desc)
    if DRY:
        return True
    try:
        fn()
        return True
    except Exception as e:
        print(f"  ERROR: {e}")
        return False

try:
    state = json.load(open(os.environ["STATE"]))
except Exception:
    state = {}

queued = {i["task"].get("url", "") for i in http("/queue/api/json?tree=items[task[url]]")["items"]}
open_prs = set()

for job in http("/api/json?tree=jobs[name,_class]")["jobs"]:
    if "MultiBranch" not in job.get("_class", ""):
        continue
    mb = job["name"]
    try:
        cfg = ET.fromstring(http(f"/job/{mb}/config.xml", raw=True))
        owner = cfg.findtext(".//repoOwner")
        name = cfg.findtext(".//repository")
    except Exception:
        continue
    if not owner or not name:
        continue
    repo = f"{owner}/{name}"
    try:
        branches = http(f"/job/{mb}/api/json?tree=jobs[name,color,url,"
                        "lastBuild[number,result,building,timestamp,duration]]").get("jobs", [])
    except Exception as e:
        print(f"skip {mb}: {e}")
        continue
    for b in branches:
        m = re.fullmatch(r"PR-(\d+)", b["name"])
        lb = b.get("lastBuild")
        if not m or not lb or b.get("color") == "disabled":
            continue
        pr = m.group(1)
        key = f"{repo}#{pr}"
        open_prs.add(key)
        if lb["building"] or any(q.endswith(f"/job/{mb}/job/{b['name']}/") for q in queued):
            continue
        if now - (lb["timestamp"] + lb["duration"]) < STALE_MS:
            continue

        result, num = lb["result"], lb["number"]
        if result == "SUCCESS":
            info = gh("pr", "view", pr, "-R", repo, "--json", "state,isDraft,url")
            if not info:
                continue
            info = json.loads(info)
            if info["state"] != "OPEN" or info["isDraft"]:
                continue
            reason, action = "green but never merged", "merge"
        elif result in ("ABORTED", "FAILURE"):
            try:
                log = http(f"/job/{mb}/job/{b['name']}/{num}/consoleText", raw=True)
            except Exception as e:   # log discarded / 404 -> cannot classify, leave it
                print(f"skip {key}: console of #{num} unreadable ({e})")
                continue
            if result == "ABORTED" and "Timeout has been exceeded" in log[-20000:]:
                reason = "aborted by timeout"
            # docker/buildkit print it lower-case ("failed to extract layer ...: no space left on device"),
            # npm prints ENOSPC; the line can be far from the end once post-actions have logged.
            elif result == "FAILURE" and re.search(r"no space left on device|ENOSPC", log, re.I):
                reason = "failed: disk full"
            else:
                continue   # ci-flow's job, or aborted by a person
            action = "rebuild"
        else:
            continue

        s = state.get(key, {})
        if s.get("build") != num or s.get("action") != action:
            if s.get("nudged") and s.get("action") == action:
                pass  # a nudge already produced a newer build that is stuck the same way -> escalate
            else:
                def do_it(action=action, mb=mb, br=b["name"], url=None):
                    if action == "rebuild":
                        http(f"/job/{mb}/job/{br}/build", method="POST", headers=crumb())
                    else:
                        body = json.dumps({"subject": f"auto-merge green PR {mb}/{br} #{num} (stale-pr-sweeper)",
                                           "job": f"{mb}/{br}", "prUrl": f"https://github.com/{repo}/pull/{pr}"})
                        subprocess.run(["docker", "exec", "jenkins", "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                                        "-X", "POST", "-H", "Content-Type: application/json", "-d", body,
                                        "http://aaf-kogito-bpmn:8080/merge-flow"], capture_output=True, text=True, check=True)
                ok = act(f"{key} {reason} (build #{num}) -> {action}", do_it)
                if ok and not DRY:
                    state[key] = {"build": num, "action": action, "nudged": True, "at": int(now)}
                continue
        if s.get("issue"):
            continue
        title = f"{MARK} {key}: {reason}"
        exists = gh("issue", "list", "-R", ISSUE_REPO, "--state", "open", "--search", f"{key} in:title", "--json", "title")
        if exists and MARK in exists and key in exists:
            continue
        body = (f"`{key}` is still stuck after one automatic {action}.\n\n"
                f"- Last build: {J.replace('http://localhost:8080', 'https://arcana.boo')}/job/{mb}/job/{b['name']}/{num}/\n"
                f"- Reason: {reason}\n- PR: https://github.com/{repo}/pull/{pr}\n\n"
                "stale-pr-sweeper will not act on this PR again. The issue closes itself once the PR is merged or closed.")
        ok = act(f"{key} still {reason} after {action} -> open issue", lambda: gh("issue", "create", "-R", ISSUE_REPO, "--title", title, "--body", body))
        if ok and not DRY:
            state.setdefault(key, {})["issue"] = True

# auto-close issues whose PR is no longer open
listing = gh("issue", "list", "-R", ISSUE_REPO, "--state", "open", "--search", f"{MARK} in:title", "--json", "number,title")
for it in json.loads(listing or "[]"):
    m = re.search(r"\] (\S+#\d+):", it["title"])
    if not m:
        continue
    repo, pr = m.group(1).split("#")
    st = gh("pr", "view", pr, "-R", repo, "--json", "state", "--jq", ".state")
    if st and st != "OPEN":
        act(f"close issue #{it['number']} ({m.group(1)} is {st})",
            lambda n=str(it["number"]), st=st: gh("issue", "close", n, "-R", ISSUE_REPO, "--comment", f"PR is {st}; closing automatically."))
        state.pop(m.group(1), None)

# forget PRs that are gone
for k in [k for k in state if k not in open_prs]:
    state.pop(k)
if not DRY:
    json.dump(state, open(os.environ["STATE"], "w"), indent=1)
print(f"sweep done: {len(open_prs)} open PR branches checked")
PYEOF
