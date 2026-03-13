// git-metrics-push.groovy
// Push commit author metrics to Prometheus Pushgateway
// Run via Jenkins Script Console: POST /jenkins/scriptText
// Scheduled by OpenClaw cron every hour

import java.net.URL
import java.net.HttpURLConnection

def repos = [
    "arcana-android":         "android-app",
    "arcana-angular":         "angular-app",
    "arcana-cloud-go":        "go-app",
    "arcana-cloud-nodejs":    "node-app",
    "arcana-cloud-python":    "python-app",
    "arcana-cloud-rust":      "rust-app",
    "arcana-cloud-springboot":"springboot-app",
    "arcana-harmonyos":       "harmonyos-app",
    "arcana-react":           "react-app",
    "arcana-vue":             "vue-app",
    "arcana-windows":         "dotnet-app",
]

def pushgw  = "http://pushgateway:9091"
def baseDir = "/data/projects"

repos.each { repoDir, projectName ->
    def dir = new File("${baseDir}/${repoDir}")
    if (!dir.exists()) return

    def proc = ["git", "-C", dir.absolutePath,
                "shortlog", "-sn", "--since=90 days ago", "HEAD"].execute()
    proc.waitFor()
    def output = proc.text.trim()
    if (!output) return

    def sb = new StringBuilder()
    sb.append("# TYPE jenkins_commits_total gauge\n")
    output.split("\n").each { line ->
        def parts = line.trim().split(/\s+/, 2)
        if (parts.length == 2) {
            def count  = parts[0].trim()
            def author = parts[1].trim().replaceAll(/["\\]/, "")
            sb.append("jenkins_commits_total{author=\"${author}\",project=\"${projectName}\"} ${count}\n")
        }
    }

    try {
        def url  = new URL("${pushgw}/metrics/job/jenkins_commits/instance/${projectName}")
        def conn = (HttpURLConnection) url.openConnection()
        conn.setRequestMethod("PUT")
        conn.setDoOutput(true)
        conn.setRequestProperty("Content-Type", "text/plain")
        conn.outputStream.write(sb.toString().bytes)
        conn.outputStream.close()
        conn.responseCode // consume
    } catch (ignored) {}
}
