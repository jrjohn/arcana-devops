#!/bin/sh
# Runs once, on the first start of an empty gh-traffic-db: create the read-only login Grafana uses.
# The collector creates its tables later as gh_traffic, so default privileges cover them too.
set -eu
psql -v ON_ERROR_STOP=1 -v ro_pw="$GH_TRAFFIC_RO_PASSWORD" --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
CREATE ROLE grafana_ro LOGIN PASSWORD :'ro_pw';
GRANT CONNECT ON DATABASE gh_traffic TO grafana_ro;
GRANT USAGE ON SCHEMA public TO grafana_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO grafana_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE gh_traffic IN SCHEMA public GRANT SELECT ON TABLES TO grafana_ro;
SQL
