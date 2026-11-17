\set ON_ERROR_STOP on
BEGIN;
\ir helpers.sql
CREATE TEMP TABLE fixture AS SELECT
  (SELECT id FROM app.workflow_versions WHERE version_no=1) AS version_id,
  (SELECT id FROM app.artifacts WHERE storage_key='synthetic://alice/input-a') AS input_id,
  (SELECT id FROM app.selection_policy_versions WHERE code='demo-policy') AS policy_id;
GRANT SELECT ON fixture TO vcp_read,vcp_write;
SET LOCAL ROLE vcp_admin;
CREATE TABLE app.permission_probe(id integer);
CREATE FUNCTION app.permission_probe_function() RETURNS integer LANGUAGE sql AS 'SELECT 1';
SET LOCAL ROLE vcp_read;
SELECT pg_temp.assert_true('reader can query comparison view',(SELECT count(*)=7 FROM app.v_research_comparison));
SELECT pg_temp.expect_error('reader cannot read raw email','SELECT email FROM app.users','42501');
SELECT pg_temp.expect_error('reader cannot read password hashes','SELECT password_hash FROM app.user_credentials','42501');
SELECT pg_temp.expect_error('reader cannot write','INSERT INTO app.workflows(owner_id,name) VALUES(gen_random_uuid(),''bad'')','42501');
SELECT pg_temp.expect_error('reader cannot truncate','TRUNCATE app.workflows CASCADE','42501');
SET LOCAL ROLE vcp_write;
SELECT pg_temp.assert_true('writer is not superuser/owner',(SELECT NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolbypassrls FROM pg_roles WHERE rolname=current_user)
  AND NOT pg_has_role(current_user,'vcp_admin','MEMBER'));
SELECT pg_temp.assert_true('writer can atomically create a launch',(SELECT app.create_run(version_id,input_id,policy_id,'balanced',gen_random_uuid(),'synthetic') IS NOT NULL FROM fixture));
SELECT pg_temp.expect_error('writer cannot read password hashes','SELECT password_hash FROM app.user_credentials','42501');
SELECT pg_temp.expect_error('writer cannot read raw email','SELECT email FROM app.users','42501');
SELECT pg_temp.expect_error('writer cannot create tables','CREATE TABLE app.forbidden(id integer)','42501');
SELECT pg_temp.expect_error('writer cannot alter schema','ALTER TABLE app.workflows ADD COLUMN forbidden integer','42501');
SELECT pg_temp.expect_error('writer cannot change operation versions','UPDATE app.operation_versions SET description=''bad''','42501');
SELECT pg_temp.expect_error('writer cannot truncate','TRUNCATE app.workflows CASCADE','42501');
SELECT pg_temp.expect_error('new tables fail closed without reviewed grants','SELECT * FROM app.permission_probe','42501');
SELECT pg_temp.expect_error('new functions are not executable by default','SELECT app.permission_probe_function()','42501');
SELECT pg_temp.assert_true('masking remains readable to reader role',has_table_privilege('vcp_read','app.v_users_masked','SELECT'));
RESET ROLE;
ROLLBACK;
