#!/usr/bin/env python3
"""Generate monitoring/grafana/dashboards/github-traffic.json (rerun after editing the panels)."""
import json
from pathlib import Path

DS = {"type": "grafana-postgresql-datasource", "uid": "gh-traffic"}
# GitHub counts days in UTC; the dashboard shows them as dates, so no timezone shift.
REPO_FILTER = "repo IN (${repo:sqlstring})"


def target(sql, fmt="time_series", ref="A"):
    return {"datasource": DS, "editorMode": "code", "format": fmt, "rawQuery": True, "rawSql": sql, "refId": ref}


def stat(title, sql, x, w=4, unit="none", desc="", y=0):
    return {"type": "stat", "title": title, "description": desc, "datasource": DS,
            "gridPos": {"h": 4 if y == 0 else 6, "w": w, "x": x, "y": y},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                        "colorMode": "value", "graphMode": "none", "textMode": "value"},
            "fieldConfig": {"defaults": {"unit": unit, "color": {"mode": "fixed", "fixedColor": "#0891b2"}}, "overrides": []},
            "targets": [target(sql, "table")]}


def ts(title, sql, y, x=0, w=24, h=8, draw="bars", desc=""):
    return {"type": "timeseries", "title": title, "description": desc, "datasource": DS,
            "gridPos": {"h": h, "w": w, "x": x, "y": y},
            "fieldConfig": {"defaults": {"custom": {"drawStyle": draw, "fillOpacity": 35, "lineWidth": 2,
                                                     "barAlignment": 0, "showPoints": "auto", "stacking": {"mode": "none"}},
                                          "unit": "none", "decimals": 0}, "overrides": []},
            "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
            "targets": [target(sql)]}


def table(title, sql, y, x, w, h=10, desc=""):
    return {"type": "table", "title": title, "description": desc, "datasource": DS,
            "gridPos": {"h": h, "w": w, "x": x, "y": y},
            "options": {"showHeader": True, "cellHeight": "sm"},
            "fieldConfig": {"defaults": {}, "overrides": []},
            "targets": [target(sql, "table")]}


panels = [
    stat("訪客(區間內,人次)", f"SELECT COALESCE(SUM(view_uniques),0) FROM repo_daily WHERE $__timeFilter(day) AND {REPO_FILTER}", 0,
         desc="每天每個 repo 的不重複訪客相加;同一人看多個 repo 會重複計算"),
    stat("瀏覽(區間內)", f"SELECT COALESCE(SUM(views),0) FROM repo_daily WHERE $__timeFilter(day) AND {REPO_FILTER}", 4),
    stat("Clone(區間內)", f"SELECT COALESCE(SUM(clones),0) FROM repo_daily WHERE $__timeFilter(day) AND {REPO_FILTER}", 8,
         desc="多半是 CI、Renovate 與 AI 代理人,不代表真人"),
    stat("星星", "SELECT COALESCE(SUM(stars),0) FROM repo_snapshot WHERE snap_day = (SELECT MAX(snap_day) FROM repo_snapshot)", 12),
    stat("追蹤者", "SELECT followers FROM account_snapshot ORDER BY snap_day DESC LIMIT 1", 16),
    stat("最後收集", "SELECT MAX(snap_day)::text FROM account_snapshot", 20, unit="string",
         desc="收集程式每 6 小時跑一次;這裡超過一天沒更新=收集程式壞了"),
    ts("每天瀏覽與訪客", f"""SELECT day::timestamp AS time, SUM(views) AS "瀏覽", SUM(view_uniques) AS "訪客"
FROM repo_daily WHERE $__timeFilter(day) AND {REPO_FILTER} GROUP BY 1 ORDER BY 1""", 4),
    ts("每週訪客趨勢", f"""SELECT date_trunc('week', day)::timestamp AS time, SUM(view_uniques) AS "訪客/週", SUM(views) AS "瀏覽/週"
FROM repo_daily WHERE $__timeFilter(day) AND {REPO_FILTER} GROUP BY 1 ORDER BY 1""", 12, w=12, draw="line"),
    ts("每天 Clone", f"""SELECT day::timestamp AS time, SUM(clones) AS "clone", SUM(clone_uniques) AS "不重複 clone"
FROM repo_daily WHERE $__timeFilter(day) AND {REPO_FILTER} GROUP BY 1 ORDER BY 1""", 12, x=12, w=12),
    table("Repo 排行(區間內)", f"""SELECT repo AS "Repo", SUM(views) AS "瀏覽", SUM(view_uniques) AS "訪客", SUM(clones) AS "Clone"
FROM repo_daily WHERE $__timeFilter(day) AND {REPO_FILTER} GROUP BY repo HAVING SUM(views) > 0 ORDER BY 2 DESC""", 20, 0, 12),
    table("外部來源(最近一次快照的 14 天)", """SELECT referrer AS "來源", SUM(uniques) AS "訪客", SUM(count) AS "瀏覽", string_agg(DISTINCT repo, ', ') AS "Repo"
FROM referrer_snapshot WHERE snap_day = (SELECT MAX(snap_day) FROM referrer_snapshot) GROUP BY referrer ORDER BY 2 DESC""", 20, 12, 12,
          desc="GitHub 只給 14 天累計,所以這裡是最新快照;github.com 是站內流量"),
    stat("README 破圖 / 不穩", "SELECT broken::text || ' / ' || flaky::text FROM badge_run ORDER BY check_day DESC LIMIT 1", 0, w=4, y=38,
         unit="string", desc="每天 08:40 用 GitHub 實際顯示的頁面、不登入抓每張圖。破圖=連 3 次(隔 2 分)都失敗,會寄信;不穩=第一次失敗、重試才好,只記錄"),
    table("破圖與不穩的圖(最近一次檢查)", """SELECT CASE WHEN persistent THEN '破圖' ELSE '不穩' END AS "狀態", repo AS "Repo", alt AS "圖", status AS "原因", original AS "網址"
FROM badge_check WHERE check_day = (SELECT MAX(check_day) FROM badge_run) ORDER BY persistent DESC, repo""", 38, 4, 20, h=6),
    ts("星星與追蹤者成長", """SELECT s.snap_day::timestamp AS time, SUM(s.stars) AS "星星", MAX(a.followers) AS "追蹤者"
FROM repo_snapshot s LEFT JOIN account_snapshot a USING (snap_day) WHERE $__timeFilter(s.snap_day) GROUP BY 1 ORDER BY 1""", 30, draw="line"),
]

dash = {
    "uid": "github-traffic", "title": "GitHub Traffic — jrjohn", "tags": ["github", "traffic"],
    "timezone": "browser", "schemaVersion": 39, "version": 1, "editable": True,
    "time": {"from": "now-90d", "to": "now"},
    "description": "GitHub 只保留 14 天流量;tools/gh-traffic 每 6 小時把看到的每一天存進 gh-traffic-db。",
    "templating": {"list": [{
        "name": "repo", "label": "Repo", "type": "query", "datasource": DS, "multi": True, "includeAll": True,
        "current": {"selected": True, "text": ["All"], "value": ["$__all"]},
        "query": "SELECT DISTINCT repo FROM repo_daily ORDER BY 1", "refresh": 2, "sort": 1}]},
    "panels": [dict(p, id=i + 1) for i, p in enumerate(panels)],
}
out = Path(__file__).resolve().parents[2] / "monitoring" / "grafana" / "dashboards" / "github-traffic.json"
out.write_text(json.dumps(dash, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("wrote", out)
