//! ci-health — the daily CI/CD health check of the bluesea fleet, as one report.
//!
//! Every item here used to be checked by hand ("目前 CI/CD 健康度"). Each check gives
//! `ok` / `warn` / `bad`; all of them go to gh-traffic-db (`health_item`, `health_run`) for the
//! Grafana dashboard, and John is mailed only when something is `bad`.
//!
//! Runs at 10:30 (after daily-ci-agent's 09:00 run, so today's report exists):
//! ```text
//! ci-health            # check, store, mail on bad
//! ci-health --dry-run  # check and print; no store, no mail
//! ```
//! Env: `DATABASE_URL`, `JENKINS_URL`, `JENKINS_CRED` (file "user:token"), `HOST_DATA`
//! (host /data mounted read-only), `GMAIL_CRED`, `ALERT_TO`, `HEALTH_CONTAINERS`,
//! `CLAUDE_CONTAINERS`. Needs the docker CLI and socket.

mod checks;

use std::error::Error;

use postgres::{Client, NoTls};

type Res<T> = Result<T, Box<dyn Error>>;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Status {
    Ok,
    Warn,
    Bad,
}

impl Status {
    fn as_str(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::Warn => "warn",
            Status::Bad => "bad",
        }
    }
    fn mark(self) -> &'static str {
        match self {
            Status::Ok => "🟢",
            Status::Warn => "🟡",
            Status::Bad => "🔴",
        }
    }
}

/// One line of the report.
#[derive(Debug)]
pub struct Item {
    pub group: &'static str,
    pub name: String,
    pub status: Status,
    /// A number to chart over time (success %, disk %, …) when the item has one.
    pub value: Option<f64>,
    pub detail: String,
}

impl Item {
    pub fn new(
        group: &'static str,
        name: impl Into<String>,
        status: Status,
        value: Option<f64>,
        detail: impl Into<String>,
    ) -> Self {
        Self {
            group,
            name: name.into(),
            status,
            value,
            detail: detail.into(),
        }
    }
}

const SCHEMA: &str = r"
CREATE TABLE IF NOT EXISTS health_run (
    check_day DATE PRIMARY KEY, ok INT NOT NULL, warn INT NOT NULL, bad INT NOT NULL);
CREATE TABLE IF NOT EXISTS health_item (
    check_day DATE NOT NULL, grp TEXT NOT NULL, name TEXT NOT NULL, status TEXT NOT NULL,
    value DOUBLE PRECISION, detail TEXT NOT NULL,
    PRIMARY KEY (check_day, grp, name));
";

fn store(db: &mut Client, items: &[Item]) -> Res<String> {
    db.batch_execute(SCHEMA)?;
    let day: String = db.query_one("SELECT CURRENT_DATE::text", &[])?.get(0);
    db.execute(
        "DELETE FROM health_item WHERE check_day = $1::text::date",
        &[&day],
    )?;
    for i in items {
        db.execute(
            "INSERT INTO health_item VALUES ($1::text::date, $2, $3, $4, $5, $6)",
            &[
                &day,
                &i.group,
                &i.name,
                &i.status.as_str(),
                &i.value,
                &i.detail,
            ],
        )?;
    }
    let count = |s: Status| {
        i32::try_from(items.iter().filter(|i| i.status == s).count()).unwrap_or(i32::MAX)
    };
    db.execute(
        "INSERT INTO health_run VALUES ($1::text::date, $2, $3, $4)
         ON CONFLICT (check_day) DO UPDATE SET ok = EXCLUDED.ok, warn = EXCLUDED.warn, bad = EXCLUDED.bad",
        &[&day, &count(Status::Ok), &count(Status::Warn), &count(Status::Bad)],
    )?;
    Ok(day)
}

fn report(items: &[Item]) -> String {
    let mut sorted: Vec<&Item> = items.iter().collect();
    sorted.sort_by(|a, b| b.status.cmp(&a.status).then(a.group.cmp(b.group)));
    sorted
        .iter()
        .map(|i| {
            format!(
                "{} {:<10} {:<34} {}",
                i.status.mark(),
                i.group,
                i.name,
                i.detail
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn send_mail(subject: &str, body: &str) -> Res<()> {
    use lettre::message::header::ContentType;
    use lettre::transport::smtp::authentication::Credentials;
    use lettre::{Message, SmtpTransport, Transport};

    let path = std::env::var("GMAIL_CRED").map_err(|_| "GMAIL_CRED is not set")?;
    let cred = std::fs::read_to_string(&path).map_err(|e| format!("{path}: {e}"))?;
    let mut parts = cred.split_whitespace();
    let (Some(user), Some(password)) = (parts.next(), parts.next()) else {
        return Err(format!("{path}: expected user and password").into());
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
    println!("mailed {to}");
    Ok(())
}

fn main() -> Res<()> {
    let dry = std::env::args().any(|a| a == "--dry-run");
    let mut db = Client::connect(
        &std::env::var("DATABASE_URL").map_err(|_| "DATABASE_URL is not set")?,
        NoTls,
    )?;
    let items = checks::all(&mut db);
    let text = report(&items);
    println!("{text}");
    let bad = items.iter().filter(|i| i.status == Status::Bad).count();
    let warn = items.iter().filter(|i| i.status == Status::Warn).count();
    println!("ci-health: {} checks, {warn} warn, {bad} bad", items.len());
    if dry {
        return Ok(());
    }
    let day = store(&mut db, &items)?;
    if bad > 0 {
        let body = format!(
            "bluesea CI/CD 健康檢查({day})有 {bad} 項異常、{warn} 項注意:\n\n{text}\n\n\
             儀表板:https://arcana.boo/grafana/d/github-traffic\n"
        );
        send_mail(&format!("[arcana-ci] CI/CD 健康檢查 {bad} 項異常"), &body)?;
    }
    Ok(())
}
