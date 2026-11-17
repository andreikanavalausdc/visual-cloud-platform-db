\set ON_ERROR_STOP on
\ir /opt/vcp/db/install.sql

\getenv app_user APP_DB_USER
\getenv app_password APP_DB_PASSWORD
BEGIN;
SET LOCAL password_encryption='scram-sha-256';
SELECT format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD %L', :'app_user', :'app_password') \gexec
SELECT format('GRANT vcp_write TO %I', :'app_user') \gexec
SELECT format('ALTER ROLE %I SET search_path=app,pg_catalog', :'app_user') \gexec
COMMIT;
\unset app_password
\unset app_user
\! touch /var/lib/postgresql/data/pgdata/.vcp-initialized
