#!/usr/bin/env python3
"""plan.py — diff image tags between repo compose files and the deployed copies.

Usage: plan.py <repo-dir> <deployed-dir>
Prints a JSON plan: {"apply": [...], "skip": [...]}.

Only image TAG changes are auto-applied (surgical, preserves the deploy
branch's local modifications — same procedure used manually for the
2026-06-05 sonarqube/nexus upgrades). Major-version bumps and image-name
changes are skipped for a human (e.g. postgres 16->18 needed dump/restore).
"""
import json
import re
import sys

FILES = ["docker-compose.yml", "docker-compose.nexus.yml", "docker-compose.monitoring.yml"]


def images(path):
    """service -> image, by naive compose walk (2-space service keys)."""
    out, svc = {}, None
    try:
        lines = open(path).read().splitlines()
    except FileNotFoundError:
        return out
    for ln in lines:
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", ln)
        if m:
            svc = m.group(1)
            continue
        m = re.match(r"^\s+image:\s*[\"']?([^\"'\s]+)[\"']?", ln)
        if m and svc:
            out.setdefault(svc, m.group(1))
    return out


def major(tag):
    m = re.match(r"v?(\d+)", tag)
    return m.group(1) if m else None


def main():
    repo, deployed = sys.argv[1], sys.argv[2]
    apply_, skip = [], []
    for f in FILES:
        want, have = images(f"{repo}/{f}"), images(f"{deployed}/{f}")
        for svc, wimg in want.items():
            himg = have.get(svc)
            if not himg or himg == wimg:
                continue
            wname, _, wtag = wimg.rpartition(":")
            hname, _, htag = himg.rpartition(":")
            item = {"file": f, "service": svc, "from": himg, "to": wimg}
            if wname != hname or not wtag or not htag:
                item["reason"] = "image name changed — manual"
                skip.append(item)
            elif major(wtag) != major(htag):
                item["reason"] = f"major bump {htag} -> {wtag} — manual (migration may be needed)"
                skip.append(item)
            else:
                apply_.append(item)
    print(json.dumps({"apply": apply_, "skip": skip}, indent=1))


if __name__ == "__main__":
    main()
