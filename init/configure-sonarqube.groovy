import jenkins.model.Jenkins
import hudson.plugins.sonar.SonarGlobalConfiguration
import hudson.plugins.sonar.SonarInstallation
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.Domain
import hudson.util.Secret

def jenkins = Jenkins.instance
def env = System.getenv()
def sonarToken = env['SONARQUBE_TOKEN'] ?: ''
def sonarUrl = env['SONAR_HOST_URL'] ?: 'http://sonarqube:9000'

// Create or update SonarQube token credential
def credId = 'sonarqube-token'
def store = jenkins.getExtensionList('com.cloudbees.plugins.credentials.SystemCredentialsProvider')[0].getStore()
def domain = Domain.global()

// Remove existing credential if present
def existing = com.cloudbees.plugins.credentials.CredentialsProvider.lookupCredentials(
    org.jenkinsci.plugins.plaincredentials.StringCredentials.class, jenkins, null, null
).find { it.id == credId }

if (existing) {
    store.removeCredentials(domain, existing)
}

if (sonarToken) {
    def cred = new StringCredentialsImpl(
        CredentialsScope.GLOBAL,
        credId,
        'SonarQube Authentication Token',
        Secret.fromString(sonarToken)
    )
    store.addCredentials(domain, cred)
    println "SonarQube credential created/updated"
}

// Configure SonarQube server
def sonarConfig = jenkins.getDescriptor(SonarGlobalConfiguration.class)
def installation = new SonarInstallation(
    'SonarQube',         // name
    sonarUrl,            // serverUrl
    sonarToken ? credId : '', // credentialsId
    null, null, null, null, null, null
)
sonarConfig.setInstallations(installation)
sonarConfig.setBuildWrapperEnabled(true)
sonarConfig.save()

println "SonarQube server configured: ${sonarUrl}"
jenkins.save()
