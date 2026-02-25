FROM jenkins/jenkins:lts

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

COPY casc.yml /var/jenkins_home/casc.yml
ENV CASC_JENKINS_CONFIG=/var/jenkins_home/casc.yml
