\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE vcp_admin;
\ir helpers.sql
CREATE TEMP TABLE fixture(k text PRIMARY KEY,id uuid NOT NULL);
INSERT INTO fixture VALUES
 ('v1',(SELECT id FROM app.workflow_versions WHERE version_no=1)),
 ('v2',(SELECT id FROM app.workflow_versions WHERE version_no=2)),
 ('alice',(SELECT id FROM app.users WHERE email='alice@example.invalid')),
 ('bob',(SELECT id FROM app.users WHERE email='bob@example.invalid')),
 ('input',(SELECT id FROM app.artifacts WHERE storage_key='synthetic://alice/input-a')),
 ('bob_input',(SELECT id FROM app.artifacts WHERE storage_key='synthetic://bob/private')),
 ('policy',(SELECT id FROM app.selection_policy_versions WHERE code='demo-policy'));

SELECT pg_temp.assert_true('13 synthetic runs, not cloud experiments',(SELECT count(*)=13 AND bool_and(data_origin='synthetic') FROM app.workflow_runs));
SELECT pg_temp.assert_true('six evaluation modes preserve failure and missing cost',(SELECT count(*)=6 AND sum(attempts)=12 AND sum(failed)=1 AND sum(missing_cost)=1 FROM app.v_research_comparison WHERE dataset_split='evaluation'));
SELECT pg_temp.assert_true('historical runs still reference v1',(SELECT bool_and(v.version_no=1) FROM app.workflow_runs r JOIN app.workflow_versions v ON v.id=r.version_id));
SELECT pg_temp.assert_true('v2 changes rule without rewriting v1',(SELECT parameters->>'value'='0' FROM app.workflow_nodes WHERE version_id=(SELECT id FROM fixture WHERE k='v1') AND node_key='filter')
  AND (SELECT parameters->>'value'='10' FROM app.workflow_nodes WHERE version_id=(SELECT id FROM fixture WHERE k='v2') AND node_key='filter'));
SELECT pg_temp.expect_error('published node cannot change',format('UPDATE app.workflow_nodes SET parameters=''{}'' WHERE version_id=%L',id),'23514','Published graph') FROM fixture WHERE k='v1';
SELECT pg_temp.expect_error('published edges cannot disappear',format('DELETE FROM app.workflow_edges WHERE version_id=%L',id),'23514','Published graph') FROM fixture WHERE k='v1';
SELECT pg_temp.expect_error('published version cannot be unfrozen',format('UPDATE app.workflow_versions SET published_at=NULL WHERE id=%L',id),'23514','Published version') FROM fixture WHERE k='v1';
SELECT pg_temp.expect_error('workflow ownership cannot be reassigned',format('UPDATE app.workflows SET owner_id=%L',id),'23514','owner') FROM fixture WHERE k='bob';
SELECT pg_temp.expect_error('duplicate version number',format('INSERT INTO app.workflow_versions(workflow_id,version_no) SELECT workflow_id,1 FROM app.workflow_versions WHERE id=%L',id),'23505') FROM fixture WHERE k='v1';
SELECT pg_temp.expect_error('plaintext password rejected',format('INSERT INTO app.user_credentials(user_id,password_hash) VALUES(%L,''plain'')',id)) FROM fixture WHERE k='bob';
SELECT pg_temp.expect_error('oversized input rejected',format('INSERT INTO app.artifacts(owner_id,storage_key,original_name,media_kind,size_bytes,state) VALUES(%L,''test:too-large'',''x.csv'',''csv'',10485761,''pending'')',id)) FROM fixture WHERE k='alice';
SELECT pg_temp.expect_error('completed file needs checksum',format('INSERT INTO app.artifacts(owner_id,storage_key,original_name,media_kind,size_bytes,state) VALUES(%L,''test:no-checksum'',''x.csv'',''csv'',1,''complete'')',id)) FROM fixture WHERE k='alice';
SELECT pg_temp.expect_error('cannot append to a published graph',format('INSERT INTO app.workflow_nodes(version_id,node_key,operation_version_id) VALUES(%L,''bad'',gen_random_uuid())',id),'23514','Published graph') FROM fixture WHERE k='v1';

WITH x AS (INSERT INTO app.workflow_versions(workflow_id,version_no) SELECT workflow_id,3 FROM app.workflow_versions WHERE version_no=1 RETURNING id)
  INSERT INTO fixture SELECT 'draft',id FROM x;
INSERT INTO app.workflow_nodes(version_id,node_key,operation_version_id,parameters,position_x)
  SELECT f.id,n.node_key,n.operation_version_id,n.parameters,n.position_x FROM app.workflow_nodes n CROSS JOIN fixture f
  WHERE n.version_id=(SELECT id FROM fixture WHERE k='v1') AND f.k='draft';
INSERT INTO app.workflow_edges SELECT (SELECT id FROM fixture WHERE k='draft'),s.id,t.id FROM app.workflow_nodes s
  JOIN app.workflow_nodes t ON t.version_id=s.version_id WHERE s.version_id=(SELECT id FROM fixture WHERE k='draft')
  AND (s.node_key,t.node_key) IN (('validate','filter'),('filter','transform'),('transform','export'));
SELECT pg_temp.expect_error('missing operation foreign key',format('INSERT INTO app.workflow_nodes(version_id,node_key,operation_version_id) VALUES(%L,''bad'',gen_random_uuid())',id),'23503') FROM fixture WHERE k='draft';
SELECT pg_temp.expect_error('cross-version edge rejected',format('INSERT INTO app.workflow_edges VALUES(%L,%L,%L)',
  (SELECT id FROM fixture WHERE k='draft'),(SELECT id FROM app.workflow_nodes WHERE version_id=(SELECT id FROM fixture WHERE k='draft') AND node_key='export'),
  (SELECT id FROM app.workflow_nodes WHERE version_id=(SELECT id FROM fixture WHERE k='v1') AND node_key='validate')),'23503');
UPDATE app.workflow_nodes SET parameters='{}' WHERE version_id=(SELECT id FROM fixture WHERE k='draft') AND node_key='validate';
SELECT pg_temp.expect_error('invalid parameters block publication',format('UPDATE app.workflow_versions SET published_at=clock_timestamp() WHERE id=%L',id),'23514','invalid CSV parameters') FROM fixture WHERE k='draft';
UPDATE app.workflow_nodes SET parameters='{"required_columns":["id","value"]}' WHERE version_id=(SELECT id FROM fixture WHERE k='draft') AND node_key='validate';
INSERT INTO app.workflow_edges SELECT s.version_id,s.id,t.id FROM app.workflow_nodes s JOIN app.workflow_nodes t ON t.version_id=s.version_id
  WHERE s.version_id=(SELECT id FROM fixture WHERE k='draft') AND s.node_key='export' AND t.node_key='validate';
SELECT pg_temp.expect_error('cycle blocks publication',format('UPDATE app.workflow_versions SET published_at=clock_timestamp() WHERE id=%L',id),'23514','cycle') FROM fixture WHERE k='draft';
DELETE FROM app.workflow_edges WHERE version_id=(SELECT id FROM fixture WHERE k='draft') AND source_node_id IN
  (SELECT id FROM app.workflow_nodes WHERE version_id=(SELECT id FROM fixture WHERE k='draft') AND node_key='export');
SELECT pg_temp.expect_error('more than 30 nodes blocks publication',format($s$DO $b$ BEGIN
  INSERT INTO app.workflow_nodes(version_id,node_key,operation_version_id,parameters)
    SELECT %L,'extra-'||g,id,'{"required_columns":["id"]}' FROM app.operation_versions CROSS JOIN generate_series(1,27) g WHERE code='csv.validate';
  UPDATE app.workflow_versions SET published_at=clock_timestamp() WHERE id=%L;
END $b$$s$,id,id),'23514','1..30 nodes') FROM fixture WHERE k='draft';

SELECT pg_temp.expect_error('unpublished version cannot launch',format('SELECT app.create_run(%L,%L,%L,''balanced'',gen_random_uuid(),''synthetic'')',
  (SELECT id FROM fixture WHERE k='draft'),(SELECT id FROM fixture WHERE k='input'),(SELECT id FROM fixture WHERE k='policy')),'23514','published active');
SELECT pg_temp.expect_error('foreign owner input cannot launch',format('SELECT app.create_run(%L,%L,%L,''balanced'',gen_random_uuid(),''synthetic'')',
  (SELECT id FROM fixture WHERE k='v1'),(SELECT id FROM fixture WHERE k='bob_input'),(SELECT id FROM fixture WHERE k='policy')),'23514','owned');
INSERT INTO fixture SELECT 'request',gen_random_uuid();
INSERT INTO fixture SELECT 'active',app.create_run((SELECT id FROM fixture WHERE k='v1'),(SELECT id FROM fixture WHERE k='input'),
  (SELECT id FROM fixture WHERE k='policy'),'balanced',(SELECT id FROM fixture WHERE k='request'),'synthetic');
SELECT pg_temp.assert_true('idempotent launch returns the same run',(SELECT id FROM fixture WHERE k='active')=app.create_run(
  (SELECT id FROM fixture WHERE k='v1'),(SELECT id FROM fixture WHERE k='input'),(SELECT id FROM fixture WHERE k='policy'),
  'balanced',(SELECT id FROM fixture WHERE k='request'),'synthetic'));
SELECT pg_temp.expect_error('request key with a changed priority is rejected',format('SELECT app.create_run(%L,%L,%L,''fastest'',%L,''synthetic'')',
  (SELECT id FROM fixture WHERE k='v1'),(SELECT id FROM fixture WHERE k='input'),(SELECT id FROM fixture WHERE k='policy'),(SELECT id FROM fixture WHERE k='request')),'23514','Idempotency');
SELECT pg_temp.assert_true('atomic launch creates all four node executions',(SELECT count(*)=4 FROM app.node_executions WHERE run_id=(SELECT id FROM fixture WHERE k='active')));
SELECT pg_temp.expect_error('node from v2 cannot execute under v1',format('INSERT INTO app.node_executions(run_id,node_id) VALUES(%L,%L)',
  (SELECT id FROM fixture WHERE k='active'),(SELECT id FROM app.workflow_nodes WHERE version_id=(SELECT id FROM fixture WHERE k='v2') AND node_key='validate')),'23514','another graph version');
SELECT pg_temp.expect_error('run snapshot cannot change',format('UPDATE app.workflow_runs SET priority=''fastest'' WHERE id=%L',id),'23514','snapshot') FROM fixture WHERE k='active';
SELECT pg_temp.expect_error('false success without outputs is rejected',format('UPDATE app.workflow_runs SET status=''succeeded'',started_at=clock_timestamp(),finished_at=clock_timestamp() WHERE id=%L',id),'23514','requires successful nodes') FROM fixture WHERE k='active';
INSERT INTO fixture SELECT 'execution',e.id FROM app.node_executions e JOIN app.workflow_nodes n ON n.id=e.node_id
  WHERE e.run_id=(SELECT id FROM fixture WHERE k='active') AND n.node_key='validate';
WITH x AS (INSERT INTO app.selection_decisions(execution_id,attempt_no,explanation)
  SELECT id,1,'Test no eligible runtime' FROM fixture WHERE k='execution' RETURNING id) INSERT INTO fixture SELECT 'rejected_decision',id FROM x;
SELECT pg_temp.expect_error('excluded candidate requires a reason',format('INSERT INTO app.decision_candidates(decision_id,runtime_configuration_id,eligible) SELECT %L,id,false FROM app.runtime_configurations WHERE environment=''worker''',id)) FROM fixture WHERE k='rejected_decision';
INSERT INTO app.decision_candidates(decision_id,runtime_configuration_id,eligible,exclusion_reason)
  SELECT f.id,rc.id,false,'Test unavailable' FROM fixture f CROSS JOIN app.runtime_configurations rc WHERE f.k='rejected_decision';
UPDATE app.selection_decisions SET sealed_at=clock_timestamp() WHERE id=(SELECT id FROM fixture WHERE k='rejected_decision');
SELECT pg_temp.expect_error('no eligible candidate means no dispatch',format('INSERT INTO app.task_attempts(decision_id) VALUES(%L)',id),'23514','eligible choice') FROM fixture WHERE k='rejected_decision';
WITH x AS (INSERT INTO app.selection_decisions(execution_id,attempt_no,explanation)
  SELECT id,2,'Test eligible decision' FROM fixture WHERE k='execution' RETURNING id) INSERT INTO fixture SELECT 'decision',id FROM x;
SELECT pg_temp.expect_error('unsealed decision cannot dispatch',format('INSERT INTO app.task_attempts(decision_id) VALUES(%L)',id),'23514','sealed eligible choice') FROM fixture WHERE k='decision';
WITH x AS (INSERT INTO app.decision_candidates(decision_id,runtime_configuration_id,eligible,predicted_ms)
  SELECT f.id,rc.id,true,100 FROM fixture f CROSS JOIN app.runtime_configurations rc WHERE f.k='decision' AND rc.environment='worker' RETURNING id)
  INSERT INTO fixture SELECT 'candidate',id FROM x;
SELECT pg_temp.expect_error('evaluation runs cannot become calibration evidence',format('INSERT INTO app.candidate_evidence_links VALUES(%L,%L)',
  (SELECT id FROM fixture WHERE k='candidate'),(SELECT r.id FROM app.workflow_runs r JOIN app.experiment_conditions c ON c.id=r.condition_id WHERE c.dataset_split='evaluation' AND r.status='succeeded' LIMIT 1)),
  '23514','calibration');
UPDATE app.selection_decisions SET selected_candidate_id=(SELECT id FROM fixture WHERE k='candidate'),sealed_at=clock_timestamp() WHERE id=(SELECT id FROM fixture WHERE k='decision');
SELECT pg_temp.expect_error('sealed candidates cannot be rewritten',format('UPDATE app.decision_candidates SET predicted_ms=10 WHERE id=%L',id),'23514','Sealed candidates') FROM fixture WHERE k='candidate';
WITH x AS (INSERT INTO app.task_attempts(decision_id) SELECT id FROM fixture WHERE k='decision' RETURNING id) INSERT INTO fixture SELECT 'attempt',id FROM x;
SELECT pg_temp.expect_error('parallel dispatch for the same node is rejected',format($s$DO $b$
  DECLARE d uuid; c uuid;
  BEGIN
    INSERT INTO app.selection_decisions(execution_id,attempt_no,explanation) VALUES(%L,3,'Test parallel attempt') RETURNING id INTO d;
    INSERT INTO app.decision_candidates(decision_id,runtime_configuration_id,eligible)
      SELECT d,id,true FROM app.runtime_configurations WHERE environment='worker' RETURNING id INTO c;
    UPDATE app.selection_decisions SET selected_candidate_id=c,sealed_at=clock_timestamp() WHERE id=d;
    INSERT INTO app.task_attempts(decision_id) VALUES(d);
  END $b$$s$,id),'23514','Another attempt is active') FROM fixture WHERE k='execution';
SELECT pg_temp.expect_error('running attempt needs dispatch reference',format('UPDATE app.task_attempts SET status=''running'',started_at=clock_timestamp() WHERE id=%L',id),'23514','dispatch reference') FROM fixture WHERE k='attempt';
SELECT pg_temp.expect_error('measurement cannot precede terminal attempt',format('INSERT INTO app.task_measurements(attempt_id,unavailable_reason) VALUES(%L,''test missing'')',id),'23514','terminal attempt') FROM fixture WHERE k='attempt';
SELECT pg_temp.expect_error('run measurement cannot precede terminal run',format('INSERT INTO app.run_measurements(run_id,unavailable_reason) VALUES(%L,''test missing'')',id),'23514','terminal run') FROM fixture WHERE k='active';
UPDATE app.task_attempts SET status='running',dispatch_reference='synthetic://test-attempt',started_at=clock_timestamp() WHERE id=(SELECT id FROM fixture WHERE k='attempt');
SELECT pg_temp.expect_error('end time before start rejected',format('UPDATE app.task_attempts SET status=''failed'',error_code=''TEST'',finished_at=queued_at-interval ''1 second'' WHERE id=%L',id)) FROM fixture WHERE k='attempt';
UPDATE app.task_attempts SET status='failed',error_code='TEST',finished_at=clock_timestamp() WHERE id=(SELECT id FROM fixture WHERE k='attempt');
SELECT pg_temp.expect_error('failed attempt cannot be rewritten as success',format('UPDATE app.task_attempts SET status=''succeeded'' WHERE id=%L',id),'23514','Terminal attempt') FROM fixture WHERE k='attempt';
SELECT pg_temp.expect_error('NULL telemetry needs an explicit reason',format('INSERT INTO app.task_measurements(attempt_id) VALUES(%L)',id)) FROM fixture WHERE k='attempt';
SELECT pg_temp.expect_error('negative cost rejected',format('INSERT INTO app.task_measurements(attempt_id,modeled_cost,cost_model_id,unavailable_reason) SELECT %L,-1,id,''test'' FROM app.cost_model_versions',id)) FROM fixture WHERE k='attempt';
SELECT pg_temp.expect_error('NaN cost rejected',format('INSERT INTO app.task_measurements(attempt_id,modeled_cost,cost_model_id,unavailable_reason) SELECT %L,''NaN'',id,''test'' FROM app.cost_model_versions',id)) FROM fixture WHERE k='attempt';
SELECT pg_temp.expect_error('wrong-owner task artifact rejected',format('INSERT INTO app.task_artifacts VALUES(%L,%L,''input'',''test'')',
  (SELECT id FROM fixture WHERE k='attempt'),(SELECT id FROM fixture WHERE k='bob_input')),'23514','Cross-owner');
SELECT pg_temp.expect_error('old file cannot be relabeled as a new output',format('INSERT INTO app.task_artifacts VALUES(%L,%L,''output'',''test'')',
  (SELECT id FROM fixture WHERE k='attempt'),(SELECT id FROM fixture WHERE k='input')),'23514','created for this attempt');
SELECT pg_temp.expect_error('failed attempt cannot supply a successful result',format('INSERT INTO app.run_results VALUES(%L,%L,%L)',
  (SELECT id FROM fixture WHERE k='active'),(SELECT id FROM fixture WHERE k='input'),(SELECT id FROM fixture WHERE k='attempt')),'23514','successful attempt');
SELECT pg_temp.expect_error('node cannot claim success from a failed attempt',format('UPDATE app.node_executions SET status=''succeeded'' WHERE id=%L',id),'23514','successful attempt') FROM fixture WHERE k='execution';
SELECT pg_temp.expect_error('failed research run cannot pass correctness',format('INSERT INTO app.run_verifications(run_id,outcome,checker_version,expected_result_key,note) VALUES(%L,''passed'',''test'',''test'',''test'')',id),'23514','successful run') FROM app.workflow_runs WHERE status='failed';
SELECT pg_temp.expect_error('transaction statement rolls back partial work',$s$DO $b$ BEGIN
  INSERT INTO app.workflows(owner_id,name) SELECT id,'must-rollback' FROM app.users LIMIT 1;
  RAISE EXCEPTION 'forced transaction failure' USING ERRCODE='P0001'; END $b$$s$,'P0001','forced');
SELECT pg_temp.assert_true('failed statement left no partial workflow',NOT EXISTS (SELECT FROM app.workflows WHERE name='must-rollback'));
UPDATE app.artifacts SET state='expired' WHERE id=(SELECT id FROM fixture WHERE k='input');
SELECT pg_temp.assert_true('same request remains idempotent after input expiry',(SELECT id FROM fixture WHERE k='active')=app.create_run(
  (SELECT id FROM fixture WHERE k='v1'),(SELECT id FROM fixture WHERE k='input'),(SELECT id FROM fixture WHERE k='policy'),'balanced',(SELECT id FROM fixture WHERE k='request'),'synthetic'));
SELECT pg_temp.expect_error('new launch cannot use expired input',format('SELECT app.create_run(%L,%L,%L,''balanced'',gen_random_uuid(),''synthetic'')',
  (SELECT id FROM fixture WHERE k='v1'),(SELECT id FROM fixture WHERE k='input'),(SELECT id FROM fixture WHERE k='policy')),'23514','available');
SELECT pg_temp.assert_true('masked account view contains no contact details',(SELECT bool_and(email='[redacted]') FROM app.v_users_masked));
SELECT pg_temp.assert_true('download metadata excludes failed runs',NOT EXISTS (SELECT FROM app.v_result_metadata m JOIN app.workflow_runs r ON r.id=m.run_id WHERE r.status<>'succeeded'));
ROLLBACK;
