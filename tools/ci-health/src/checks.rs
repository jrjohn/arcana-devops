//! The individual checks. A check that cannot run reports `bad` ("無法檢查"), never `ok`:
//! a health check that silently skips a part is worse than none.

use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use postgres::Client;
use serde_json::Value;

use crate::{Item, Res, Status};

const DAY_MS: f64 = 86_400_000.0;

fn env(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn sh(program: &str, args: &[&str]) -> Res<String> {
    let out = Command::new(program).args(args).output()?;
    if !out.status.success() {
        return Err(format!(
            "{program} {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        )
        .into());
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn now_ms() -> f64 {
    #[allow(clippy::cast_precision_loss)]
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis()) as f64;
    ms
}

fn base64(input: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in input.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(T[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

// ---- thresholds (pure, tested) ----

/// A main branch: red now = bad; over 7 days below 80 % success (with ≥ 3 builds) = warn.
pub fn main_branch(color: &str, ok: usize, total: usize) -> Status {
    if color.starts_with("red") {
        Status::Bad
    } else if total >= 3 && ok * 100 < total * 80 {
        Status::Warn
    } else {
        Status::Ok
    }
}

/// Disk use in percent: ≥ 85 bad (Sonar goes read-only near full, 2026-09), ≥ 75 warn.
pub fn disk(percent: f64) -> Status {
    if percent >= 85.0 {
        Status::Bad
    } else if percent >= 75.0 {
        Status::Warn
    } else {
        Status::Ok
    }
}

/// Swap in use: ≥ 95 % is warn only — it has sat full for weeks without an outage.
pub fn swap(used_percent: f64) -> Status {
    if used_percent >= 95.0 {
        Status::Warn
    } else {
        Status::Ok
    }
}

/// Today's daily-agent report is missing: still running = warn, finished without it = bad.
pub fn daily_report_missing(still_running: bool) -> Status {
    if still_running {
        Status::Warn
    } else {
        Status::Bad
    }
}

/// Age in days of something that should happen daily: > 1 bad.
pub fn freshness(age_days: i32) -> Status {
    if age_days > 1 {
        Status::Bad
    } else {
        Status::Ok
    }
}

// ---- checks ----

fn jenkins(items: &mut Vec<Item>) -> Res<()> {
    let url = env("JENKINS_URL", "http://jenkins:8080/jenkins");
    let cred_path = env("JENKINS_CRED", "/run/jenkins-cred");
    let cred = std::fs::read_to_string(&cred_path).map_err(|e| format!("{cred_path}: {e}"))?;
    let auth = format!("Basic {}", base64(cred.trim().as_bytes()));
    let get = |path: &str| -> Res<Value> {
        Ok(ureq::get(&format!("{url}{path}"))
            .header("Authorization", &auth)
            .config()
            .timeout_global(Some(Duration::from_secs(30)))
            .build()
            .call()?
            .body_mut()
            .read_json::<Value>()?)
    };
    let since = now_ms() - 7.0 * DAY_MS;
    let jobs = get("/api/json?tree=jobs[name,jobs[name,color,builds[result,timestamp]{0,60}]]")?;
    let (mut ok_all, mut total_all) = (0usize, 0usize);
    for job in jobs["jobs"].as_array().into_iter().flatten() {
        let Some(main) = job["jobs"]
            .as_array()
            .and_then(|b| b.iter().find(|b| b["name"] == "main"))
        else {
            continue;
        };
        let color = main["color"].as_str().unwrap_or("");
        let builds: Vec<&Value> = main["builds"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|b| b["timestamp"].as_f64().unwrap_or(0.0) > since && b["result"].is_string())
            .collect();
        let ok = builds.iter().filter(|b| b["result"] == "SUCCESS").count();
        ok_all += ok;
        total_all += builds.len();
        let name = job["name"]
            .as_str()
            .unwrap_or("?")
            .trim_end_matches("-pipeline-mb")
            .trim_end_matches("-mb");
        #[allow(clippy::cast_precision_loss)]
        let pct = (!builds.is_empty()).then(|| ok as f64 * 100.0 / builds.len() as f64);
        items.push(Item::new(
            "jenkins",
            name,
            main_branch(color, ok, builds.len()),
            pct,
            format!("main {color}, 7 天 {ok}/{}", builds.len()),
        ));
    }
    #[allow(clippy::cast_precision_loss)]
    let pct = (total_all > 0).then(|| ok_all as f64 * 100.0 / total_all as f64);
    items.push(Item::new(
        "jenkins",
        "全部 main(7 天)",
        Status::Ok,
        pct,
        format!("{ok_all}/{total_all}"),
    ));

    let nodes = get("/computer/api/json?tree=computer[displayName,offline]")?;
    for n in nodes["computer"].as_array().into_iter().flatten() {
        let name = n["displayName"].as_str().unwrap_or("?");
        let offline = n["offline"] == Value::Bool(true);
        items.push(Item::new(
            "node",
            name,
            if offline { Status::Bad } else { Status::Ok },
            None,
            if offline { "離線" } else { "在線" },
        ));
    }
    Ok(())
}

fn containers(items: &mut Vec<Item>) {
    let names = env(
        "HEALTH_CONTAINERS",
        "jenkins,sonarqube,sonarqube-db,grafana,prometheus,daily-ci-agent,agent-task-node,aaf-task-worker,aaf-kogito-bpmn,aaf-data-index,gh-traffic-db",
    );
    for name in names.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        let item = match sh("docker", &["inspect", "-f", "{{.State.Status}}", name]) {
            Ok(s) if s.trim() == "running" => {
                Item::new("container", name, Status::Ok, None, "running")
            }
            Ok(s) => Item::new("container", name, Status::Bad, None, s.trim()),
            Err(e) => Item::new(
                "container",
                name,
                Status::Bad,
                None,
                format!("無法檢查: {e}"),
            ),
        };
        items.push(item);
    }
}

fn claude(items: &mut Vec<Item>) {
    for name in env("CLAUDE_CONTAINERS", "daily-ci-agent,agent-task-node")
        .split(',')
        .map(str::trim)
    {
        let version = sh("docker", &["exec", name, "claude", "--version"])
            .map(|v| v.lines().next().unwrap_or("").to_string());
        let answer = sh(
            "docker",
            &[
                "exec",
                name,
                "sh",
                "-c",
                "cd /tmp && timeout 120 claude -p '只回覆兩個字:正常' 2>&1 | head -1",
            ],
        );
        let item = match (version, answer) {
            (Ok(v), Ok(a)) if a.contains("正常") => {
                Item::new("claude", name, Status::Ok, None, format!("{v},回答正常"))
            }
            (Ok(v), Ok(a)) => Item::new(
                "claude",
                name,
                Status::Bad,
                None,
                format!("{v},回答異常: {}", a.trim()),
            ),
            (Err(e), _) | (_, Err(e)) => {
                Item::new("claude", name, Status::Bad, None, format!("無法檢查: {e}"))
            }
        };
        items.push(item);
    }
}

fn ci_flow(items: &mut Vec<Item>) {
    // docker logs writes the worker's output to stderr as well; read both.
    let out = Command::new("docker")
        .args(["logs", "--since", "24h", "aaf-task-worker"])
        .output();
    let Ok(out) = out else {
        items.push(Item::new(
            "ci-flow",
            "24 小時處理量",
            Status::Bad,
            None,
            "無法檢查: docker logs",
        ));
        return;
    };
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let count = |k: &str| text.matches(k).count();
    let budget = count("BUDGET EXCEEDED");
    let detail = format!(
        "合併 {}、發版 {}、修復 {}、預算上限 {budget}",
        count("✓ Merge"),
        count("✓ Release"),
        count("✓ Fix")
    );
    #[allow(clippy::cast_precision_loss)]
    let merges = Some(count("✓ Merge") as f64);
    items.push(Item::new(
        "ci-flow",
        "24 小時處理量",
        if budget > 0 { Status::Warn } else { Status::Ok },
        merges,
        detail,
    ));
}

fn host(items: &mut Vec<Item>) {
    let data = env("HOST_DATA", "/host-data");
    match sh("df", &["-P", &data]) {
        Ok(out) => {
            let pct = out
                .lines()
                .nth(1)
                .and_then(|l| l.split_whitespace().nth(4))
                .and_then(|p| p.trim_end_matches('%').parse::<f64>().ok());
            match pct {
                Some(p) => items.push(Item::new(
                    "host",
                    "/data 磁碟",
                    disk(p),
                    Some(p),
                    format!("{p:.0}%"),
                )),
                None => items.push(Item::new(
                    "host",
                    "/data 磁碟",
                    Status::Bad,
                    None,
                    "無法檢查: df 輸出看不懂",
                )),
            }
        }
        Err(e) => items.push(Item::new(
            "host",
            "/data 磁碟",
            Status::Bad,
            None,
            format!("無法檢查: {e}"),
        )),
    }
    let meminfo = std::fs::read_to_string("/proc/meminfo").unwrap_or_default();
    let kb = |k: &str| {
        meminfo
            .lines()
            .find(|l| l.starts_with(k))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|v| v.parse::<f64>().ok())
    };
    match (kb("SwapTotal:"), kb("SwapFree:")) {
        (Some(t), Some(f)) if t > 0.0 => {
            let used = (t - f) * 100.0 / t;
            items.push(Item::new(
                "host",
                "swap",
                swap(used),
                Some(used),
                format!("{used:.0}% 已用"),
            ));
        }
        _ => items.push(Item::new("host", "swap", Status::Ok, None, "沒有 swap")),
    }
}

fn reports(items: &mut Vec<Item>, today: &str) {
    let data = env("HOST_DATA", "/host-data");
    let path = format!("{data}/ci-reports/{today}.md");
    if let Ok(text) = std::fs::read_to_string(&path) {
        let field = |k: &str| {
            text.lines()
                .find(|l| l.contains(k))
                .map(|l| l.split(':').nth(1).unwrap_or("").trim().to_string())
        };
        let red = field("Red pipelines start of day").unwrap_or_default();
        let review = field("Needs human review").unwrap_or_default();
        items.push(Item::new(
            "daily-agent",
            "今天的巡檢報告",
            Status::Ok,
            None,
            format!(
                "開工紅燈 {}; 待人處理 {}",
                red.chars().take(40).collect::<String>(),
                review.chars().take(50).collect::<String>()
            ),
        ));
    } else {
        // A run that is still going is not a failure: on 2026-11-13 the agent was 1 h 37 min in at
        // 10:30 and this check mailed John a false "bad". Only a finished run without a report is.
        {
            let running = sh(
                "docker",
                &[
                    "exec",
                    "daily-ci-agent",
                    "pgrep",
                    "-f",
                    "^bash /usr/local/bin/daily-run.sh",
                ],
            )
            .is_ok_and(|out| !out.trim().is_empty());
            items.push(Item::new(
                "daily-agent",
                "今天的巡檢報告",
                daily_report_missing(running),
                None,
                if running {
                    format!("{path} 還沒寫出來:巡檢仍在執行中")
                } else {
                    format!("{path} 不存在(巡檢沒跑或沒寫報告)")
                },
            ));
        }
    }
    let log = format!("{data}/projects/claude-agents-workflow/weekly-rebuild.log");
    let last = std::fs::read_to_string(&log).ok().and_then(|t| {
        t.lines()
            .rev()
            .find(|l| l.contains('✅') || l.contains('❌'))
            .map(str::to_string)
    });
    let item = match last {
        Some(l) if l.contains('❌') => {
            Item::new("daily-agent", "每週 Claude CLI 重建", Status::Bad, None, l)
        }
        Some(l) => Item::new(
            "daily-agent",
            "每週 Claude CLI 重建",
            Status::Ok,
            None,
            l.chars().take(80).collect::<String>(),
        ),
        None => Item::new(
            "daily-agent",
            "每週 Claude CLI 重建",
            Status::Bad,
            None,
            format!("無法檢查: {log}"),
        ),
    };
    items.push(item);
}

fn traffic(db: &mut Client, items: &mut Vec<Item>) {
    for (name, sql) in [
        (
            "GitHub 流量收集",
            "SELECT (CURRENT_DATE - MAX(snap_day))::int FROM account_snapshot",
        ),
        (
            "README 破圖檢查",
            "SELECT (CURRENT_DATE - MAX(check_day))::int FROM badge_run",
        ),
    ] {
        let age: Option<i32> = db.query_one(sql, &[]).ok().and_then(|r| r.get(0));
        items.push(match age {
            Some(a) => Item::new(
                "gh-traffic",
                name,
                freshness(a),
                None,
                format!("最後一次是 {a} 天前"),
            ),
            None => Item::new("gh-traffic", name, Status::Bad, None, "無法檢查:沒有資料"),
        });
    }
    if let Ok(row) = db.query_one(
        "SELECT broken FROM badge_run ORDER BY check_day DESC LIMIT 1",
        &[],
    ) {
        let broken: i32 = row.get(0);
        items.push(Item::new(
            "gh-traffic",
            "README 破圖數",
            if broken > 0 { Status::Bad } else { Status::Ok },
            Some(f64::from(broken)),
            format!("{broken} 張"),
        ));
    }
}

/// Files in Jenkins workspaces not owned by the Jenkins user: a container that ran as root wrote
/// them, and the next checkout cannot delete them ("Failed to delete workspace", esp32 main red
/// 5x on 2026-11-14). Warn before that happens.
fn workspaces(items: &mut Vec<Item>) {
    let ws = env("JENKINS_WORKSPACES", "/jenkins-workspace");
    let uid = env("JENKINS_UID", "1000");
    match sh("find", &[&ws, "!", "-user", &uid, "-print"]) {
        Ok(out) => {
            let mut per: std::collections::BTreeMap<String, usize> =
                std::collections::BTreeMap::new();
            for line in out.lines() {
                let rel = line.trim_start_matches(&ws).trim_start_matches('/');
                if let Some(top) = rel.split('/').next().filter(|s| !s.is_empty()) {
                    *per.entry(top.to_string()).or_default() += 1;
                }
            }
            let total: usize = per.values().sum();
            let detail = if per.is_empty() {
                "沒有".to_string()
            } else {
                per.iter()
                    .map(|(k, v)| format!("{k} {v}"))
                    .collect::<Vec<_>>()
                    .join(", ")
            };
            #[allow(clippy::cast_precision_loss)]
            let value = Some(total as f64);
            items.push(Item::new(
                "jenkins",
                "工作目錄的 root 檔案",
                if total > 0 { Status::Warn } else { Status::Ok },
                value,
                detail,
            ));
        }
        Err(e) => items.push(Item::new(
            "jenkins",
            "工作目錄的 root 檔案",
            Status::Bad,
            None,
            format!("無法檢查: {e}"),
        )),
    }
}

pub fn all(db: &mut Client) -> Vec<Item> {
    let today: String = db
        .query_one("SELECT (now() AT TIME ZONE 'Asia/Taipei')::date::text", &[])
        .map_or_else(|_| String::new(), |r| r.get(0));
    let mut items = Vec::new();
    if let Err(e) = jenkins(&mut items) {
        items.push(Item::new(
            "jenkins",
            "Jenkins API",
            Status::Bad,
            None,
            format!("無法檢查: {e}"),
        ));
    }
    workspaces(&mut items);
    containers(&mut items);
    claude(&mut items);
    ci_flow(&mut items);
    host(&mut items);
    reports(&mut items, &today);
    traffic(db, &mut items);
    items
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn main_branch_thresholds() {
        assert_eq!(main_branch("red", 10, 10), Status::Bad);
        assert_eq!(main_branch("red_anime", 0, 0), Status::Bad);
        assert_eq!(main_branch("blue", 3, 5), Status::Warn); // windows on Wi-Fi: 60 %
        assert_eq!(main_branch("blue", 4, 5), Status::Ok); // exactly 80 %
        assert_eq!(main_branch("blue", 1, 2), Status::Ok); // too few builds to judge
        assert_eq!(main_branch("blue_anime", 9, 12), Status::Warn); // 75 %
    }

    #[test]
    fn host_thresholds() {
        assert_eq!(disk(65.0), Status::Ok);
        assert_eq!(disk(75.0), Status::Warn);
        assert_eq!(disk(85.0), Status::Bad);
        assert_eq!(swap(99.6), Status::Warn);
        assert_eq!(freshness(0), Status::Ok);
        assert_eq!(freshness(1), Status::Ok);
        assert_eq!(freshness(2), Status::Bad);
        assert_eq!(daily_report_missing(true), Status::Warn);
        assert_eq!(daily_report_missing(false), Status::Bad);
    }

    #[test]
    fn base64_matches_rfc4648() {
        assert_eq!(base64(b"admin:pw"), "YWRtaW46cHc=");
        assert_eq!(base64(b"ab"), "YWI=");
        assert_eq!(base64(b"abc"), "YWJj");
    }
}
