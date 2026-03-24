FROM jenkins/jenkins:lts

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

USER root
ARG SONAR_SCANNER_VERSION=8.0.1.6346
ARG NODE_VERSION=24.14.0
ARG NEXUS_URL=http://172.17.0.1:8081/nexus/repository
ENV SONAR_SCANNER_HOME=/opt/sonar-scanner
RUN apt-get update && apt-get install -y --no-install-recommends unzip xz-utils ca-certificates \
    && ARCH=$(dpkg --print-architecture) \
    && NODE_ARCH=$([ "$ARCH" = "arm64" ] && echo "arm64" || echo "x64") \
    && curl -fsSL -o /tmp/node.tar.xz \
       "${NEXUS_URL}/nodejs-dist-proxy/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && curl -fsSL -o /tmp/sonar-scanner.zip \
       "${NEXUS_URL}/sonarsource-proxy/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}.zip" \
    && unzip /tmp/sonar-scanner.zip -d /opt \
    && mv /opt/sonar-scanner-${SONAR_SCANNER_VERSION} ${SONAR_SCANNER_HOME} \
    && rm /tmp/sonar-scanner.zip \
    && apt-get purge -y unzip xz-utils && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
ENV PATH="${SONAR_SCANNER_HOME}/bin:${PATH}"
USER jenkins

ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"

COPY casc.yml /var/jenkins_home/casc.yml
ENV CASC_JENKINS_CONFIG=/var/jenkins_home/casc.yml
