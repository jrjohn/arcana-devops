// Arcana CI trigger (B2, 2026-06-06 v5): on a non-SUCCESS build, create a ci-flow
// BPMN instance on the workflow engine. The BPMN flow + task-worker own
// diagnose(Triage=ai)/build(Build=jenkins)/fix(Fix=ai)/decide(Decide=ai).
// Never blocks the build.
//
// v4: DEDUP — skip when an ACTIVE ci-flow instance already exists for the job.
// v5: COOLDOWN — also skip when ANY ci-flow instance for the job started within
//     the last 6h, regardless of state. Without this the system is a perpetual
//     motion machine: an escalated flow's own rebuild fails -> B2 sees a fresh
//     red build with no ACTIVE instance -> spawns the next flow -> hourly
//     rebuild+AI loop per red PR, forever (2026-06-06: 45 instances/day, one
//     vue PR rebuilt 17x). Escalate means a human is needed; retrying hourly
//     buys nothing. Fail-open: a dedup-check error still spawns.
//
// Deployed at: $JENKINS_HOME/init.groovy.d/ci-routine-trigger.groovy (runs at
// boot). Live-apply without restart: POST this file to /jenkins/scriptText
// (crumb + cookie session) — registration below is idempotent.
import hudson.model.Run
import hudson.model.listeners.RunListener
import groovy.json.JsonOutput

class CiBpmnTrigger extends RunListener<Run> {
    static final int COOLDOWN_HOURS = 6
    CiBpmnTrigger() { super(Run.class) }
    @Override void onFinalized(Run run) {
        try {
            def result = run.getResult()?.toString() ?: "UNKNOWN"
            if (result == "SUCCESS") return
            def job = run.getParent().getFullName()
            def num = run.getNumber()
            def buildUrl = "http://jenkins:8080/jenkins/" + run.getUrl()
            Thread.start {
                try {
                    // v5 dedup+cooldown: skip if this job has an ACTIVE flow OR any
                    // flow started in the last COOLDOWN_HOURS (see header).
                    try {
                        def cutoff = java.time.Instant.now()
                            .minusSeconds(COOLDOWN_HOURS * 3600L).toString()
                        def dq = JsonOutput.toJson([query:
                            '{ ProcessInstances(where:{and:[{processId:{equal:"ci-flow"}},' +
                            '{or:[{state:{equal:ACTIVE}},{start:{greaterThan:"' + cutoff + '"}}]}]})' +
                            '{ variables } }'])
                        def dconn = new URL("http://aaf-data-index:8080/graphql").openConnection()
                        dconn.setRequestMethod("POST")
                        dconn.setRequestProperty("Content-Type", "application/json")
                        dconn.setConnectTimeout(5000); dconn.setReadTimeout(10000); dconn.setDoOutput(true)
                        dconn.getOutputStream().withWriter("UTF-8") { it << dq }
                        def dresp = dconn.getInputStream().getText("UTF-8")
                        if (dresp.contains('"job":"' + job + '"')) {
                            println("[ci-bpmn-trigger] ${job} #${num} (${result}) -> SKIP (active flow or <${COOLDOWN_HOURS}h cooldown)")
                            return
                        }
                    } catch (Throwable dt) {
                        println("[ci-bpmn-trigger] dedup check failed (${dt}) — spawning anyway")
                    }
                    def body = [subject: "${job} #${num} ${result}".toString(),
                                job: job, buildUrl: buildUrl, result: result]
                    def conn = new URL("http://aaf-kogito-bpmn:8080/ci-flow").openConnection()
                    conn.setRequestMethod("POST")
                    conn.setRequestProperty("Content-Type", "application/json")
                    conn.setConnectTimeout(8000); conn.setReadTimeout(15000); conn.setDoOutput(true)
                    conn.getOutputStream().withWriter("UTF-8") { it << JsonOutput.toJson(body) }
                    def code = conn.getResponseCode()
                    println("[ci-bpmn-trigger] ${job} #${num} (${result}) -> ci-flow instance HTTP ${code}")
                } catch (Throwable t) {
                    println("[ci-bpmn-trigger] async error ${job} #${num}: ${t}")
                }
            }
        } catch (Throwable t) {
            println("[ci-bpmn-trigger] onFinalized error: ${t}")
        }
    }
}
// idempotent re-register: remove the old inline-routine listener AND any prior bpmn one
def __el = RunListener.all()
new ArrayList(__el).findAll { it.getClass().getSimpleName() in ["CiRoutineTrigger", "CiBpmnTrigger"] }.each { __el.remove(it) }
__el.add(new CiBpmnTrigger())
println("[ci-bpmn-trigger] registered v5 (B2: red build -> ci-flow; dedup ACTIVE + 6h cooldown per job)")
