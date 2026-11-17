\set ON_ERROR_STOP on

DO $roles$
DECLARE n text;
BEGIN
  FOREACH n IN ARRAY ARRAY['vcp_admin','vcp_read','vcp_write'] LOOP
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname=n) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',n);
    ELSIF EXISTS (SELECT FROM pg_roles WHERE rolname=n AND
      (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls OR rolcanlogin)) THEN
      RAISE EXCEPTION 'Existing role % has unexpected privileges; use a dedicated cluster',n;
    END IF;
  END LOOP;
END $roles$;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION vcp_admin;
REVOKE ALL ON SCHEMA app FROM PUBLIC;
GRANT USAGE ON SCHEMA app TO vcp_read,vcp_write;
ALTER DEFAULT PRIVILEGES FOR ROLE vcp_admin REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

