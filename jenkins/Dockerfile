FROM jenkins/jenkins:lts

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

USER root
ARG SONAR_SCANNER_VERSION=8.0.1.6346
ARG NODE_MAJOR=24
ENV SONAR_SCANNER_HOME=/opt/sonar-scanner
RUN apt-get update && apt-get install -y --no-install-recommends unzip ca-certificates gnupg \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && curl -fsSL -o /tmp/sonar-scanner.zip \
       "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}.zip" \
    && unzip /tmp/sonar-scanner.zip -d /opt \
    && mv /opt/sonar-scanner-${SONAR_SCANNER_VERSION} ${SONAR_SCANNER_HOME} \
    && rm /tmp/sonar-scanner.zip \
    && apt-get purge -y unzip gnupg && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
ENV PATH="${SONAR_SCANNER_HOME}/bin:${PATH}"
USER jenkins

ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"

COPY casc.yml /var/jenkins_home/casc.yml
ENV CASC_JENKINS_CONFIG=/var/jenkins_home/casc.yml
