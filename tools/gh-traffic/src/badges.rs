//! `gh-traffic badges` — find README images that visitors actually see as broken.
//!
//! An image URL answering 200 is not enough: GitHub shows external images through its camo
//! proxy, which gives up after a few seconds, so a slow badge (a shields.io *dynamic* badge
//! that must fetch a raw file first) is broken on the page while a direct fetch works
//! (arcana-harmonyos, 2026-11-06). So this reads the README the way GitHub renders it and
//! fetches every `<img src>` anonymously, exactly as a visitor's browser would.
//!
//! camo also times out now and then on a healthy badge. One failure proves nothing, so a
//! failing image is fetched again after `RETRY_WAIT`, three times in all, and only an image
//! that fails every time is reported (table `badge_check`, plus a mail when one is found).

use std::collections::BTreeMap;
use std::time::Duration;

use postgres::Client;

use crate::{Github, Res, today};

const ATTEMPTS: usize = 3;
const RETRY_WAIT: Duration = Duration::from_secs(120);

pub const SCHEMA: &str = r"
CREATE TABLE IF NOT EXISTS badge_run (
    check_day DATE PRIMARY KEY, repos INT NOT NULL, images INT NOT NULL, broken INT NOT NULL);
CREATE TABLE IF NOT EXISTS badge_check (
    check_day DATE NOT NULL, repo TEXT NOT NULL, src TEXT NOT NULL,
    alt TEXT NOT NULL, original TEXT NOT NULL, status TEXT NOT NULL,
    PRIMARY KEY (check_day, repo, src));
";

/// One `<img>` as GitHub rendered it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Image {
    pub src: String,
    pub alt: String,
    /// The URL the README author wrote (`data-canonical-src`), or `src` when GitHub kept it.
    pub original: String,
}

fn attr(tag: &str, name: &str) -> Option<String> {
    let key = format!(" {name}=\"");
    let start = tag.find(&key)? + key.len();
    let end = tag[start..].find('"')? + start;
    Some(unescape(&tag[start..end]))
}

fn unescape(s: &str) -> String {
    s.replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
}

/// Every `<img>` in rendered README HTML, in document order, without duplicates.
pub fn images(html: &str) -> Vec<Image> {
    let mut out: Vec<Image> = Vec::new();
    let mut rest = html;
    while let Some(i) = rest.find("<img") {
        let tail = &rest[i..];
        let end = tail.find('>').unwrap_or(tail.len());
        let tag = &tail[..end];
        if let Some(src) = attr(tag, "src") {
            let original = attr(tag, "data-canonical-src").unwrap_or_else(|| src.clone());
            let image = Image {
                alt: attr(tag, "alt").unwrap_or_default(),
                original,
                src,
            };
            if !out.iter().any(|o| o.src == image.src) {
                out.push(image);
            }
        }
        rest = &tail[end..];
    }
    out
}

/// What a visitor's browser gets: `None` = an image, `Some(why)` = broken.
fn fetch(agent: &ureq::Agent, url: &str) -> Option<String> {
    match agent
        .get(url)
        .header("User-Agent", "Mozilla/5.0 (arcana badge check)")
        .call()
    {
        Ok(resp) => {
            let ct = resp
                .headers()
                .get("content-type")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_ascii_lowercase();
            if ct.starts_with("image/") || ct.contains("svg") {
                None
            } else {
                Some(format!("200 but content-type {ct}"))
            }
        }
        Err(ureq::Error::StatusCode(code)) => Some(format!("HTTP {code}")),
        Err(e) => Some(e.to_string()),
    }
}

/// The URL a browser would request: relative paths resolve to the repo file, and a space
/// (legal in a Markdown path such as `docs/screen/User Manager.png`) is sent as `%20`.
fn absolute(src: &str, owner: &str, repo: &str) -> String {
    let url = if src.starts_with("http://") || src.starts_with("https://") {
        src.to_string()
    } else {
        format!(
            "https://github.com/{owner}/{repo}/raw/HEAD/{}",
            src.trim_start_matches("./").trim_start_matches('/')
        )
    };
    url.replace(' ', "%20")
}

pub fn run(
    db: &mut Client,
    gh: &Github,
    owner: &str,
    mail: impl Fn(&str, &str) -> Res<()>,
) -> Res<()> {
    db.batch_execute(SCHEMA)?;
    let day = today(db)?;
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(20)))
        .build()
        .into();

    // (repo, image) for every image on every public README.
    let mut all: Vec<(String, Image)> = Vec::new();
    let mut repos = 0;
    for r in gh.owned_repos()? {
        let (Some(name), false) = (
            r["name"].as_str(),
            r["private"] == serde_json::Value::Bool(true),
        ) else {
            continue;
        };
        let Ok(html) = gh.get_text(
            &format!("repos/{owner}/{name}/readme"),
            "application/vnd.github.html",
        ) else {
            continue;
        };
        repos += 1;
        all.extend(images(&html).into_iter().map(|i| (name.to_string(), i)));
    }

    let mut failing: BTreeMap<usize, String> = BTreeMap::new();
    for (i, (repo, img)) in all.iter().enumerate() {
        if let Some(why) = fetch(&agent, &absolute(&img.src, owner, repo)) {
            failing.insert(i, why);
        }
    }
    for _ in 1..ATTEMPTS {
        if failing.is_empty() {
            break;
        }
        std::thread::sleep(RETRY_WAIT);
        failing.retain(|i, why| {
            let (repo, img) = &all[*i];
            match fetch(&agent, &absolute(&img.src, owner, repo)) {
                Some(again) => {
                    *why = again;
                    true
                }
                None => false,
            }
        });
    }

    db.execute(
        "DELETE FROM badge_check WHERE check_day = $1::text::date",
        &[&day],
    )?;
    let mut lines = Vec::new();
    for (i, why) in &failing {
        let (repo, img) = &all[*i];
        db.execute(
            "INSERT INTO badge_check VALUES ($1::text::date, $2, $3, $4, $5, $6)",
            &[&day, repo, &img.src, &img.alt, &img.original, why],
        )?;
        lines.push(format!(
            "  {repo}  [{}]  {why}\n      {}",
            img.alt, img.original
        ));
    }
    let (images, broken) = (i32::try_from(all.len())?, i32::try_from(failing.len())?);
    db.execute(
        "INSERT INTO badge_run VALUES ($1::text::date, $2, $3, $4)
         ON CONFLICT (check_day) DO UPDATE SET repos = EXCLUDED.repos, images = EXCLUDED.images, broken = EXCLUDED.broken",
        &[&day, &repos, &images, &broken],
    )?;
    println!(
        "badges {day}: {repos} repos, {images} images, {broken} broken after {ATTEMPTS} tries"
    );
    for l in &lines {
        println!("{l}");
    }
    if !lines.is_empty() {
        let body = format!(
            "GitHub README 有 {broken} 張圖,連續 {ATTEMPTS} 次(間隔 {} 分鐘)都載不出來:\n\n{}\n\n\
             檢查方式:用 GitHub 實際顯示的頁面、不登入去抓每張圖(跟訪客看到的一樣)。\n\
             儀表板:https://arcana.boo/grafana/d/github-traffic\n",
            RETRY_WAIT.as_secs() / 60,
            lines.join("\n")
        );
        mail(
            &format!("[arcana-ci] GitHub README 有 {broken} 張破圖"),
            &body,
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_src_alt_and_canonical_and_skips_duplicates() {
        let html = r#"<p><a href="x"><img src="https://camo.githubusercontent.com/ab" alt="API" data-canonical-src="https://img.shields.io/badge/dynamic/json?url=a&amp;query=b" style="max-width: 100%;"></a>
            <img src="docs/a.png" alt="Shot"><img src="https://camo.githubusercontent.com/ab" alt="API"></p>"#;
        let got = images(html);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].alt, "API");
        assert_eq!(
            got[0].original,
            "https://img.shields.io/badge/dynamic/json?url=a&query=b"
        );
        assert_eq!(
            got[1],
            Image {
                src: "docs/a.png".into(),
                alt: "Shot".into(),
                original: "docs/a.png".into()
            }
        );
    }

    #[test]
    fn relative_paths_point_at_the_repo_file() {
        assert_eq!(
            absolute("./docs/a b.png", "jrjohn", "r"),
            "https://github.com/jrjohn/r/raw/HEAD/docs/a%20b.png"
        );
        assert_eq!(
            absolute("https://x/y.svg", "jrjohn", "r"),
            "https://x/y.svg"
        );
    }

    /// Proves the check can fail: a missing repo file and a non-image page must both be
    /// reported, a real badge must not. Needs the network: `cargo test -- --ignored`.
    #[test]
    #[ignore = "network"]
    fn a_missing_image_is_reported_and_a_real_one_is_not() {
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(20)))
            .build()
            .into();
        let missing = absolute("docs/no-such-file.png", "jrjohn", "arcana-ios");
        assert!(
            fetch(&agent, &missing).is_some(),
            "missing file must be broken"
        );
        assert!(
            fetch(&agent, "https://github.com/jrjohn").is_some(),
            "an HTML page is not an image"
        );
        assert!(
            fetch(&agent, "https://img.shields.io/badge/a-b-blue").is_none(),
            "a static badge is fine"
        );
    }
}
