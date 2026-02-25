import jenkins.model.Jenkins
import java.io.File

def jenkins = Jenkins.instance
def jobsDir = new File("/var/jenkins_home/jobs-config")

if (jobsDir.exists()) {
    jobsDir.listFiles().findAll { it.name.endsWith('.xml') }.each { file ->
        def jobName = file.name.replace('.xml', '')
        if (jenkins.getItem(jobName) == null) {
            def stream = new FileInputStream(file)
            jenkins.createProjectFromXML(jobName, stream)
            stream.close()
            println "Created job: ${jobName}"
        } else {
            println "Job already exists: ${jobName}"
        }
    }
    jenkins.save()
    println "Job import complete."
} else {
    println "No jobs-config directory found at /var/jenkins_home/jobs-config"
}
