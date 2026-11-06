//! gh-traffic — keep GitHub traffic beyond the API's 14-day window.
//!
//! GitHub only serves the last 14 days of views/clones/referrers. This tool stores every
//! day it sees in Postgres (upsert, so re-running is harmless) for the Grafana dashboard
//! `monitoring/grafana/dashboards/github-traffic.json`.
//!
//! ```text
//! gh-traffic collect          # fetch all repos of GH_OWNER now (cron, every 6 h)
//! gh-traffic import <dir>     # load a saved snapshot dir (snap-YYYYMMDD/<repo>.{views,clones,ref}.json)
//! gh-traffic badges           # README images visitors see as broken (cron, daily; mails John)
//! ```
//! Env: `DATABASE_URL`, `GH_TRAFFIC_TOKEN` (needs Administration: read), `GH_OWNER`,
//! `GMAIL_CRED` (badges: file with `user` and app password on two lines), `ALERT_TO`.

mod badges;

use std::error::Error;
use std::path::Path;

use postgres::{Client, NoTls};
use serde_json::Value;

type Res<T> = Result<T, Box<dyn Error>>;

const SCHEMA: &str = r"
CREATE TABLE IF NOT EXISTS repo_daily (
    repo TEXT NOT NULL, day DATE NOT NULL,
    views INT NOT NULL DEFAULT 0, view_uniques INT NOT NULL DEFAULT 0,
    clones INT NOT NULL DEFAULT 0, clone_uniques INT NOT NULL DEFAULT 0,
    PRIMARY KEY (repo, day));
CREATE TABLE IF NOT EXISTS referrer_snapshot (
    snap_day DATE NOT NULL, repo TEXT NOT NULL, referrer TEXT NOT NULL,
    count INT NOT NULL, uniques INT NOT NULL,
    PRIMARY KEY (snap_day, repo, referrer));
CREATE TABLE IF NOT EXISTS repo_snapshot (
    snap_day DATE NOT NULL, repo TEXT NOT NULL,
    stars INT NOT NULL, forks INT NOT NULL, private BOOLEAN NOT NULL,
    PRIMARY KEY (snap_day, repo));
CREATE TABLE IF NOT EXISTS account_snapshot (
    snap_day DATE PRIMARY KEY, followers INT NOT NULL);
";

/// The day GitHub reports is complete only once it is over, so a later fetch of the same
/// day can only be larger: keep the maximum instead of overwriting with a partial count.
const UPSERT_VIEWS: &str =
    "INSERT INTO repo_daily (repo, day, views, view_uniques) VALUES ($1, $2::text::date, $3, $4)
    ON CONFLICT (repo, day) DO UPDATE SET views = GREATEST(repo_daily.views, EXCLUDED.views),
    view_uniques = GREATEST(repo_daily.view_uniques, EXCLUDED.view_uniques)";
const UPSERT_CLONES: &str =
    "INSERT INTO repo_daily (repo, day, clones, clone_uniques) VALUES ($1, $2::text::date, $3, $4)
    ON CONFLICT (repo, day) DO UPDATE SET clones = GREATEST(repo_daily.clones, EXCLUDED.clones),
    clone_uniques = GREATEST(repo_daily.clone_uniques, EXCLUDED.clone_uniques)";
const UPSERT_REFERRER: &str = "INSERT INTO referrer_snapshot VALUES ($1::text::date, $2, $3, $4, $5)
    ON CONFLICT (snap_day, repo, referrer) DO UPDATE SET count = EXCLUDED.count, uniques = EXCLUDED.uniques";

fn int(v: &Value, key: &str) -> i32 {
    v.get(key)
        .and_then(Value::as_i64)
        .and_then(|n| i32::try_from(n).ok())
        .unwrap_or(0)
}

fn day(ts: &Value) -> Option<&str> {
    ts.as_str().and_then(|s| s.get(..10))
}

/// Write one repo's views/clones/referrers JSON (the GitHub API shapes) into the database.
fn store(
    db: &mut Client,
    repo: &str,
    snap_day: &str,
    views: &Value,
    clones: &Value,
    refs: &Value,
) -> Res<u64> {
    let mut rows = 0;
    for v in views["views"].as_array().into_iter().flatten() {
        if let Some(d) = day(&v["timestamp"]) {
            rows += db.execute(
                UPSERT_VIEWS,
                &[&repo, &d, &int(v, "count"), &int(v, "uniques")],
            )?;
        }
    }
    for c in clones["clones"].as_array().into_iter().flatten() {
        if let Some(d) = day(&c["timestamp"]) {
            rows += db.execute(
                UPSERT_CLONES,
                &[&repo, &d, &int(c, "count"), &int(c, "uniques")],
            )?;
        }
    }
    for r in refs.as_array().into_iter().flatten() {
        if let Some(name) = r["referrer"].as_str() {
            db.execute(
                UPSERT_REFERRER,
                &[
                    &snap_day,
                    &repo,
                    &name,
                    &int(r, "count"),
                    &int(r, "uniques"),
                ],
            )?;
        }
    }
    Ok(rows)
}

struct Github {
    agent: ureq::Agent,
    auth: String,
}

impl Github {
    fn new(token: &str) -> Self {
        Self {
            agent: ureq::Agent::new_with_defaults(),
            auth: format!("Bearer {token}"),
        }
    }

    fn get(&self, path: &str) -> Res<Value> {
        let url = format!("https://api.github.com/{path}");
        let mut resp = self
            .agent
            .get(&url)
            .header("Authorization", &self.auth)
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "arcana-gh-traffic")
            .call()
            .map_err(|e| format!("GET {url}: {e}"))?;
        Ok(resp.body_mut().read_json::<Value>()?)
    }

    /// An API resource in another media type, such as a README rendered to HTML.
    fn get_text(&self, path: &str, accept: &str) -> Res<String> {
        let url = format!("https://api.github.com/{path}");
        let mut resp = self
            .agent
            .get(&url)
            .header("Authorization", &self.auth)
            .header("Accept", accept)
            .header("User-Agent", "arcana-gh-traffic")
            .call()
            .map_err(|e| format!("GET {url}: {e}"))?;
        Ok(resp.body_mut().read_to_string()?)
    }

    /// Every repo the token's user owns, private ones included, forks excluded.
    fn owned_repos(&self) -> Res<Vec<Value>> {
        let mut all = Vec::new();
        for page in 1.. {
            let batch = self.get(&format!(
                "user/repos?affiliation=owner&per_page=100&page={page}"
            ))?;
            let items = batch.as_array().cloned().unwrap_or_default();
            if items.is_empty() {
                break;
            }
            all.extend(items.into_iter().filter(|r| r["fork"] != Value::Bool(true)));
        }
        Ok(all)
    }
}

fn today(db: &mut Client) -> Res<String> {
    Ok(db.query_one("SELECT CURRENT_DATE::text", &[])?.get(0))
}

fn collect(db: &mut Client) -> Res<()> {
    let token = std::env::var("GH_TRAFFIC_TOKEN").map_err(|_| "GH_TRAFFIC_TOKEN is not set")?;
    let owner = std::env::var("GH_OWNER").unwrap_or_else(|_| "jrjohn".into());
    let gh = Github::new(&token);
    let snap = today(db)?;
    let (mut ok, mut failed) = (0, Vec::new());
    for r in gh.owned_repos()? {
        let Some(name) = r["name"].as_str() else {
            continue;
        };
        let base = format!("repos/{owner}/{name}/traffic");
        let fetched = gh.get(&format!("{base}/views")).and_then(|v| {
            Ok((
                v,
                gh.get(&format!("{base}/clones"))?,
                gh.get(&format!("{base}/popular/referrers"))?,
            ))
        });
        match fetched {
            Ok((views, clones, refs)) => {
                store(db, name, &snap, &views, &clones, &refs)?;
                db.execute(
                    "INSERT INTO repo_snapshot VALUES ($1::text::date, $2, $3, $4, $5)
                     ON CONFLICT (snap_day, repo) DO UPDATE SET stars = EXCLUDED.stars, forks = EXCLUDED.forks, private = EXCLUDED.private",
                    &[&snap, &name, &int(&r, "stargazers_count"), &int(&r, "forks_count"), &(r["private"] == Value::Bool(true))],
                )?;
                ok += 1;
            }
            Err(e) => failed.push(format!("{name}: {e}")),
        }
    }
    let followers = int(&gh.get(&format!("users/{owner}"))?, "followers");
    db.execute(
        "INSERT INTO account_snapshot VALUES ($1::text::date, $2) ON CONFLICT (snap_day) DO UPDATE SET followers = EXCLUDED.followers",
        &[&snap, &followers],
    )?;
    println!(
        "collect {snap}: {ok} repos stored, {} failed, followers={followers}",
        failed.len()
    );
    for f in &failed {
        eprintln!("  {f}");
    }
    // A repo-level failure (e.g. the token lost access) must not look like a quiet success.
    if ok == 0 || !failed.is_empty() {
        Err(format!("{} repo(s) failed", failed.len()).into())
    } else {
        Ok(())
    }
}

fn import(db: &mut Client, dir: &Path) -> Res<()> {
    let snap = dir
        .file_name()
        .and_then(|n| n.to_str())
        .and_then(|n| n.strip_prefix("snap-"))
        .filter(|d| d.len() == 8)
        .map(|d| format!("{}-{}-{}", &d[..4], &d[4..6], &d[6..]))
        .ok_or("directory must be named snap-YYYYMMDD")?;
    let read = |p: &Path| -> Value {
        std::fs::read_to_string(p)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or(Value::Null)
    };
    let mut repos = 0;
    let mut rows = 0;
    for entry in std::fs::read_dir(dir)? {
        let path = entry?.path();
        let Some(repo) = path
            .file_name()
            .and_then(|n| n.to_str())
            .and_then(|n| n.strip_suffix(".views.json"))
        else {
            continue;
        };
        let views = read(&path);
        let clones = read(&dir.join(format!("{repo}.clones.json")));
        let refs = read(&dir.join(format!("{repo}.ref.json")));
        rows += store(db, repo, &snap, &views, &clones, &refs)?;
        repos += 1;
    }
    println!("import {snap}: {repos} repos, {rows} daily rows upserted");
    Ok(())
}

fn main() -> Res<()> {
    let url = std::env::var("DATABASE_URL").map_err(|_| "DATABASE_URL is not set")?;
    let mut db = Client::connect(&url, NoTls)?;
    db.batch_execute(SCHEMA)?;
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None | Some("collect") => collect(&mut db),
        Some("import") => import(
            &mut db,
            Path::new(
                args.get(1)
                    .ok_or("usage: gh-traffic import <snap-YYYYMMDD dir>")?,
            ),
        ),
        Some("badges") => {
            let token =
                std::env::var("GH_TRAFFIC_TOKEN").map_err(|_| "GH_TRAFFIC_TOKEN is not set")?;
            let owner = std::env::var("GH_OWNER").unwrap_or_else(|_| "jrjohn".into());
            badges::run(&mut db, &Github::new(&token), &owner, send_mail)
        }
        Some(other) => {
            Err(format!("unknown command {other}; use collect | import <dir> | badges").into())
        }
    }
}

/// Mail John through Gmail, with the credentials daily-ci-agent already uses.
fn send_mail(subject: &str, body: &str) -> Res<()> {
    use lettre::message::header::ContentType;
    use lettre::transport::smtp::authentication::Credentials;
    use lettre::{Message, SmtpTransport, Transport};

    let cred_path = std::env::var("GMAIL_CRED").map_err(|_| "GMAIL_CRED is not set")?;
    let cred = std::fs::read_to_string(&cred_path).map_err(|e| format!("{cred_path}: {e}"))?;
    let mut parts = cred.split_whitespace();
    let (Some(user), Some(password)) = (parts.next(), parts.next()) else {
        return Err(format!("{cred_path}: expected user and password").into());
    };
    let to = std::env::var("ALERT_TO").unwrap_or_else(|_| "jr.johnchang@gmail.com".into());
    let msg = Message::builder()
        .from(format!("Arcana CI <{user}>").parse()?)
        .to(to.parse()?)
        .subject(subject)
        .header(ContentType::TEXT_PLAIN)
        .body(body.to_string())?;
    SmtpTransport::relay("smtp.gmail.com")?
        .credentials(Credentials::new(user.to_string(), password.to_string()))
        .build()
        .send(&msg)?;
    println!("  mailed {to}");
    Ok(())
}
