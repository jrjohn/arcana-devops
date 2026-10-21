#!/usr/bin/env python3
"""claude-token-alert — mail John when the bluesea Claude CLI burns too fast.

Reads the session transcripts every agent container on bluesea writes
(agent-task-node and daily-ci-agent share CLAUDE_HOME), sums OUTPUT tokens over the
last WINDOW_MIN minutes and mails when the sum exceeds THRESHOLD. At most one mail per
COOLDOWN_MIN so a runaway cannot flood the inbox.

Why output tokens: cache reads are ~100x larger and cheap, so a cache-inclusive
threshold fires on every normal remediation (measured 2026-10-19: 154 of 197 half-hour
windows over 100K). Output tokens track how much work the model actually did.

Why this exists: the 2026-09-14 alert lived inside agent-task-node and mailed through
SendGrid, whose credits had run out — it never sent a single mail while ci-flow burned
2.1B tokens in 72h (2026-10-19). This runs on the host, outside ai bpm, and sends via
Gmail SMTP with the credentials already used by daily-ci-agent.

Usage:
  claude-token-alert.py            # cron: check and mail if over threshold
  claude-token-alert.py --dry-run  # print what it would do, never mail
  claude-token-alert.py --test     # send one test mail now (verifies delivery)
"""
import datetime as dt
import glob
import json
import os
import smtplib
import ssl
import sys
from collections import Counter
from email.mime.text import MIMEText

CLAUDE_HOME = os.environ.get("CLAUDE_HOME", "/data/projects/daily-ci-agent/claude-home")
GMAIL_CRED = os.environ.get("GMAIL_CRED", CLAUDE_HOME + "/.gmail-smtp")  # "user\npassword"
TO = os.environ.get("ALERT_TO", "jr.johnchang@gmail.com")
WINDOW_MIN = int(os.environ.get("WINDOW_MIN", "30"))
THRESHOLD = int(os.environ.get("THRESHOLD", "100000"))
COOLDOWN_MIN = int(os.environ.get("COOLDOWN_MIN", "60"))
STATE = os.environ.get("STATE", "/var/lib/claude-token-alert/last-sent")
TW = dt.timezone(dt.timedelta(hours=8))
# Long-lived token from `claude setup-token` (1 year). set-claude-longlived-token.sh writes the
# issue date (YYYY-MM-DD) here; mail once a day when fewer than EXPIRY_WARN_DAYS remain.
TOKEN_ISSUED = os.environ.get("TOKEN_ISSUED", CLAUDE_HOME + "/.oauth-token-issued")
TOKEN_LIFETIME_DAYS = int(os.environ.get("TOKEN_LIFETIME_DAYS", "365"))
EXPIRY_WARN_DAYS = int(os.environ.get("EXPIRY_WARN_DAYS", "14"))
EXPIRY_STATE = os.environ.get("EXPIRY_STATE", "/var/lib/claude-token-alert/expiry-last-sent")


def first_prompt(path):
    """First user prompt of a session = what the agent was asked to do."""
    try:
        with open(path, errors="ignore") as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if d.get("type") == "user":
                    c = (d.get("message") or {}).get("content")
                    text = c if isinstance(c, str) else json.dumps(c, ensure_ascii=False)
                    return " ".join(text.split())[:120]
    except OSError:
        pass
    return "?"


def scan(now):
    since = now - dt.timedelta(minutes=WINDOW_MIN)
    total, calls, per_session = 0, 0, Counter()
    files = glob.glob(CLAUDE_HOME + "/projects/*/*.jsonl") + glob.glob(
        CLAUDE_HOME + "/projects/*/*/subagents/*.jsonl")
    for f in files:
        if os.path.getmtime(f) < since.timestamp():
            continue
        with open(f, errors="ignore") as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                usage = (d.get("message") or {}).get("usage")
                ts = d.get("timestamp")
                if not usage or not ts:
                    continue
                t = dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                if t < since:
                    continue
                o = usage.get("output_tokens", 0)
                total += o
                calls += 1
                per_session[f] += o
    return total, calls, per_session


def body(now, total, calls, per_session):
    lines = [
        "bluesea 上的 Claude CLI 最近 %d 分鐘輸出了 %s tokens(門檻 %s),%d 次呼叫。"
        % (WINDOW_MIN, format(total, ","), format(THRESHOLD, ","), calls),
        "",
        "用最多的工作:",
    ]
    for f, o in per_session.most_common(5):
        lines.append("  %8s  %s" % (format(o, ","), first_prompt(f)))
    lines += [
        "",
        "時間(台灣):" + now.astimezone(TW).strftime("%Y-%m-%d %H:%M"),
        "查細節:ssh bluesea,看 %s/projects/-root/ 下最新的 *.jsonl" % CLAUDE_HOME,
        "這封信 %d 分鐘內不會再寄。" % COOLDOWN_MIN,
    ]
    return "\n".join(lines)


def send(subject, text):
    with open(GMAIL_CRED) as fh:
        user, password = fh.read().split()[:2]
    msg = MIMEText(text, "plain", "utf-8")
    msg["Subject"], msg["From"], msg["To"] = subject, "Arcana CI <%s>" % user, TO
    with smtplib.SMTP_SSL("smtp.gmail.com", 465, context=ssl.create_default_context(),
                          timeout=20) as s:
        s.login(user, password)
        s.sendmail(user, [TO], msg.as_string())


def cooling_down(now):
    try:
        with open(STATE) as fh:
            last = dt.datetime.fromisoformat(fh.read().strip())
        return now - last < dt.timedelta(minutes=COOLDOWN_MIN)
    except (OSError, ValueError):
        return False


def mark_sent(now):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE, "w") as fh:
        fh.write(now.isoformat())


def check_expiry(now, dry):
    """Warn before the 1-year agent token dies (the 2026-10-21 outage: /login refresh tokens
    expire after 30 days and every AI step on bluesea stopped with no mail)."""
    try:
        with open(TOKEN_ISSUED) as fh:
            issued = dt.date.fromisoformat(fh.read().strip())
    except (OSError, ValueError):
        return
    left = (issued + dt.timedelta(days=TOKEN_LIFETIME_DAYS) - now.astimezone(TW).date()).days
    if left > EXPIRY_WARN_DAYS:
        return
    today = now.astimezone(TW).date().isoformat()
    try:
        with open(EXPIRY_STATE) as fh:
            if fh.read().strip() == today:
                return
    except OSError:
        pass
    text = ("bluesea 的 Claude 長效 token(claude setup-token)%s。\n發行日 %s,有效 %d 天。\n"
            "換新:在 Mac 跑 bash ~/set-claude-longlived-token.sh(要開瀏覽器同意一次)。"
            % ("已過期" if left < 0 else "還剩 %d 天到期" % left, issued, TOKEN_LIFETIME_DAYS))
    subject = "[arcana-ci] Claude token %s" % ("已過期" if left < 0 else "%d 天後到期" % left)
    print("  token expiry:", subject)
    if dry:
        return
    send(subject, text)
    os.makedirs(os.path.dirname(EXPIRY_STATE), exist_ok=True)
    with open(EXPIRY_STATE, "w") as fh:
        fh.write(today)


def main(argv):
    now = dt.datetime.now(dt.timezone.utc)
    if "--test" not in argv:
        check_expiry(now, "--dry-run" in argv)
    if "--test" in argv:
        send("[arcana-ci] 測試:Claude token 告警", "這是測試信,告警腳本能寄信。")
        print("test mail sent to", TO)
        return 0
    total, calls, per_session = scan(now)
    stamp = now.astimezone(TW).strftime("%m-%d %H:%M")
    print("%s output=%s calls=%d threshold=%s" % (stamp, format(total, ","), calls,
                                                 format(THRESHOLD, ",")))
    if total <= THRESHOLD:
        return 0
    if cooling_down(now):
        print("  over threshold, cooling down — not mailing")
        return 0
    text = body(now, total, calls, per_session)
    subject = "[arcana-ci] Claude %d 分鐘輸出 %s tokens(> %s)" % (
        WINDOW_MIN, format(total, ","), format(THRESHOLD, ","))
    if "--dry-run" in argv:
        print("  DRY RUN would mail:\n" + text)
        return 0
    send(subject, text)
    mark_sent(now)
    print("  mailed", TO)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
