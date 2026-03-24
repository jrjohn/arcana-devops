FROM python:3-alpine
WORKDIR /app
COPY requirements.txt .
ARG NEXUS_URL=http://172.17.0.1:8081/nexus/repository
RUN pip install --no-cache-dir --index-url ${NEXUS_URL}/pypi-proxy/simple/ --trusted-host 172.17.0.1 -r requirements.txt
COPY exporter.py .
CMD ["python", "exporter.py"]
