\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE vcp_admin;
SET LOCAL search_path=app,pg_catalog;

CREATE FUNCTION reject_mutation() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
BEGIN RAISE EXCEPTION '% is append-only; create a new version or correction migration',TG_TABLE_NAME USING ERRCODE='23514'; END $$;
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['operation_versions','runtime_configurations','selection_policy_versions','cost_model_versions','experiment_conditions','task_measurements','run_measurements'] LOOP
    EXECUTE format('CREATE TRIGGER immutable_record BEFORE UPDATE OR DELETE ON app.%I FOR EACH ROW EXECUTE FUNCTION app.reject_mutation()',t);
  END LOOP;
END $$;

CREATE FUNCTION valid_parameters(p_code text,p jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,app AS $$
BEGIN
  IF jsonb_typeof(p)<>'object' THEN RETURN false; END IF;
  CASE p_code
    WHEN 'csv.validate' THEN
      IF jsonb_typeof(p->'required_columns') IS DISTINCT FROM 'array' THEN RETURN false; END IF;
      RETURN jsonb_array_length(p->'required_columns')>0
        AND NOT EXISTS (SELECT FROM jsonb_array_elements(p->'required_columns') x
          WHERE jsonb_typeof(x)<>'string' OR length(btrim(x #>> '{}'))=0)
        AND (SELECT count(*) FROM jsonb_object_keys(p))=1;
    WHEN 'csv.filter' THEN
      RETURN coalesce(jsonb_typeof(p->'column')='string' AND length(btrim(p->>'column'))>0
        AND p->>'operator' IN ('gt','lt','eq') AND jsonb_typeof(p->'value')='number'
        AND (SELECT count(*) FROM jsonb_object_keys(p))=3,false);
    WHEN 'csv.transform' THEN
      RETURN coalesce(jsonb_typeof(p->'source')='string' AND jsonb_typeof(p->'target')='string'
        AND length(btrim(p->>'source'))>0 AND length(btrim(p->>'target'))>0
        AND p->>'source'<>p->>'target' AND (SELECT count(*) FROM jsonb_object_keys(p))=2,false);
    WHEN 'csv.export' THEN
      RETURN coalesce(p->>'delimiter' IN (',',';') AND (SELECT count(*) FROM jsonb_object_keys(p))=1,false);
    ELSE RETURN false;
  END CASE;
END $$;

CREATE FUNCTION guard_graph_edit() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
DECLARE v uuid; pub timestamptz;
BEGIN
  IF TG_OP='UPDATE' AND NEW.version_id<>OLD.version_id THEN
    RAISE EXCEPTION 'A graph record cannot move between versions' USING ERRCODE='23514';
  END IF;
  v:=CASE WHEN TG_OP='DELETE' THEN OLD.version_id ELSE NEW.version_id END;
  SELECT published_at INTO pub FROM app.workflow_versions WHERE id=v FOR UPDATE;
  IF pub IS NOT NULL THEN RAISE EXCEPTION 'Published graph is immutable' USING ERRCODE='23514'; END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END $$;
CREATE TRIGGER node_edit BEFORE INSERT OR UPDATE OR DELETE ON workflow_nodes FOR EACH ROW EXECUTE FUNCTION guard_graph_edit();
CREATE TRIGGER edge_edit BEFORE INSERT OR UPDATE OR DELETE ON workflow_edges FOR EACH ROW EXECUTE FUNCTION guard_graph_edit();

CREATE FUNCTION guard_version() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
DECLARE n integer;
BEGIN
  IF TG_OP<>'INSERT' AND OLD.published_at IS NOT NULL THEN
    RAISE EXCEPTION 'Published version is immutable' USING ERRCODE='23514';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  IF TG_OP='UPDATE' AND ROW(NEW.id,NEW.workflow_id,NEW.version_no,NEW.created_at)
    IS DISTINCT FROM ROW(OLD.id,OLD.workflow_id,OLD.version_no,OLD.created_at) THEN
    RAISE EXCEPTION 'Version identity is immutable' USING ERRCODE='23514';
  END IF;
  IF NEW.published_at IS NOT NULL THEN
    SELECT count(*) INTO n FROM app.workflow_nodes WHERE version_id=NEW.id;
    IF n NOT BETWEEN 1 AND 30 THEN RAISE EXCEPTION 'A published graph needs 1..30 nodes' USING ERRCODE='23514'; END IF;
    IF EXISTS (SELECT FROM app.workflow_nodes x JOIN app.operation_versions o ON o.id=x.operation_version_id
      WHERE x.version_id=NEW.id AND NOT app.valid_parameters(o.code,x.parameters)) THEN
      RAISE EXCEPTION 'Unsupported operation or invalid CSV parameters' USING ERRCODE='23514';
    END IF;
    IF EXISTS (SELECT FROM app.workflow_edges e JOIN app.workflow_nodes s ON s.id=e.source_node_id
      JOIN app.operation_versions so ON so.id=s.operation_version_id JOIN app.workflow_nodes t ON t.id=e.target_node_id
      JOIN app.operation_versions too ON too.id=t.operation_version_id
      WHERE e.version_id=NEW.id AND so.output_kind<>too.input_kind) THEN
      RAISE EXCEPTION 'Incompatible edge data types' USING ERRCODE='23514';
    END IF;
    IF EXISTS (WITH RECURSIVE reach(s,t) AS (
      SELECT source_node_id,target_node_id FROM app.workflow_edges WHERE version_id=NEW.id
      UNION SELECT r.s,e.target_node_id FROM reach r JOIN app.workflow_edges e ON e.source_node_id=r.t WHERE e.version_id=NEW.id
    ) SELECT FROM reach WHERE s=t) THEN
      RAISE EXCEPTION 'Workflow contains a cycle' USING ERRCODE='23514';
    END IF;
    
    IF (SELECT count(*) FROM app.workflow_edges WHERE version_id=NEW.id)<>n-1
      OR EXISTS (SELECT FROM app.workflow_edges WHERE version_id=NEW.id GROUP BY source_node_id HAVING count(*)>1)
      OR EXISTS (SELECT FROM app.workflow_edges WHERE version_id=NEW.id GROUP BY target_node_id HAVING count(*)>1) THEN
      RAISE EXCEPTION 'CSV core requires one sequential path' USING ERRCODE='23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER version_guard BEFORE INSERT OR UPDATE OR DELETE ON workflow_versions FOR EACH ROW EXECUTE FUNCTION guard_version();

CREATE FUNCTION guard_owner() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
BEGIN
  IF NEW.owner_id<>OLD.owner_id OR NEW.id<>OLD.id THEN
    RAISE EXCEPTION 'Resource identity and owner are immutable' USING ERRCODE='23514';
  END IF;
  IF TG_TABLE_NAME='artifacts' THEN
    IF OLD.state<>'pending' AND ROW(NEW.storage_key,NEW.original_name,NEW.media_kind,NEW.size_bytes,NEW.decoded_pixels,NEW.sha256,NEW.created_at,NEW.expires_at)
      IS DISTINCT FROM ROW(OLD.storage_key,OLD.original_name,OLD.media_kind,OLD.size_bytes,OLD.decoded_pixels,OLD.sha256,OLD.created_at,OLD.expires_at) THEN
      RAISE EXCEPTION 'Completed artifact content metadata is immutable' USING ERRCODE='23514';
    END IF;
    IF NEW.state<>OLD.state AND NOT ((OLD.state='pending' AND NEW.state IN ('complete','deleted')) OR
      (OLD.state='complete' AND NEW.state IN ('expired','deleted')) OR (OLD.state='expired' AND NEW.state='deleted')) THEN
      RAISE EXCEPTION 'Invalid artifact lifecycle transition' USING ERRCODE='23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER workflow_owner BEFORE UPDATE ON workflows FOR EACH ROW EXECUTE FUNCTION guard_owner();
CREATE TRIGGER artifact_owner BEFORE UPDATE ON artifacts FOR EACH ROW EXECUTE FUNCTION guard_owner();

CREATE FUNCTION guard_run() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
DECLARE w app.workflows%ROWTYPE; a app.artifacts%ROWTYPE; pub timestamptz; c app.experiment_conditions%ROWTYPE;
BEGIN
  IF TG_OP='UPDATE' THEN
    IF OLD.status IN ('succeeded','failed','cancelled') THEN RAISE EXCEPTION 'Terminal run is immutable' USING ERRCODE='23514'; END IF;
    IF ROW(NEW.id,NEW.version_id,NEW.input_artifact_id,NEW.policy_version_id,NEW.priority,NEW.condition_id,NEW.trial_no,NEW.data_origin,NEW.request_key,NEW.accepted_at)
      IS DISTINCT FROM ROW(OLD.id,OLD.version_id,OLD.input_artifact_id,OLD.policy_version_id,OLD.priority,OLD.condition_id,OLD.trial_no,OLD.data_origin,OLD.request_key,OLD.accepted_at) THEN
      RAISE EXCEPTION 'Run snapshot is immutable' USING ERRCODE='23514';
    END IF;
    IF OLD.started_at IS NOT NULL AND NEW.started_at IS DISTINCT FROM OLD.started_at THEN
      RAISE EXCEPTION 'Run start time is immutable once observed' USING ERRCODE='23514';
    END IF;
    IF NEW.status='accepted' AND OLD.status='running' THEN RAISE EXCEPTION 'Run cannot go backwards' USING ERRCODE='23514'; END IF;
    IF NEW.status='succeeded' AND (NOT EXISTS (SELECT FROM app.run_results WHERE run_id=NEW.id)
      OR EXISTS (SELECT FROM app.node_executions WHERE run_id=NEW.id AND status<>'succeeded')) THEN
      RAISE EXCEPTION 'Successful run requires successful nodes and a bound result' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
  END IF;
  SELECT v.published_at INTO pub FROM app.workflow_versions v WHERE v.id=NEW.version_id FOR SHARE;
  SELECT wf.* INTO w FROM app.workflows wf JOIN app.workflow_versions v ON v.workflow_id=wf.id WHERE v.id=NEW.version_id FOR SHARE OF wf;
  IF pub IS NULL OR w.archived_at IS NOT NULL THEN RAISE EXCEPTION 'Run needs a published active workflow' USING ERRCODE='23514'; END IF;
  IF NOT EXISTS (SELECT FROM app.users WHERE id=w.owner_id AND is_active) THEN RAISE EXCEPTION 'Inactive owner' USING ERRCODE='23514'; END IF;
  SELECT * INTO a FROM app.artifacts WHERE id=NEW.input_artifact_id FOR SHARE;
  IF a.owner_id IS DISTINCT FROM w.owner_id OR a.state IS DISTINCT FROM 'complete' OR a.expires_at<=clock_timestamp() THEN
    RAISE EXCEPTION 'Input must be complete, available and owned by the workflow owner' USING ERRCODE='23514';
  END IF;
  IF EXISTS (SELECT FROM app.workflow_nodes n JOIN app.operation_versions o ON o.id=n.operation_version_id
    WHERE n.version_id=NEW.version_id AND NOT EXISTS (SELECT FROM app.workflow_edges e WHERE e.target_node_id=n.id)
    AND o.input_kind<>a.media_kind) THEN RAISE EXCEPTION 'Input format does not match root operation' USING ERRCODE='23514'; END IF;
  IF NEW.condition_id IS NOT NULL THEN
    SELECT * INTO c FROM app.experiment_conditions WHERE id=NEW.condition_id;
    IF c.scenario IS DISTINCT FROM a.media_kind OR (c.mode LIKE 'auto_%' AND c.mode IS DISTINCT FROM 'auto_'||NEW.priority) THEN
      RAISE EXCEPTION 'Research condition differs from launch configuration' USING ERRCODE='23514';
    END IF;
  END IF;
  IF NEW.status<>'accepted' THEN RAISE EXCEPTION 'Create runs in accepted state' USING ERRCODE='23514'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER run_guard BEFORE INSERT OR UPDATE ON workflow_runs FOR EACH ROW EXECUTE FUNCTION guard_run();

CREATE FUNCTION create_run(p_version uuid,p_input uuid,p_policy uuid,p_priority text,p_request uuid,
  p_origin text DEFAULT 'observed',p_condition uuid DEFAULT NULL,p_trial integer DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
DECLARE r app.workflow_runs%ROWTYPE; result uuid;
BEGIN
  
  PERFORM pg_advisory_xact_lock(hashtextextended(p_version::text||p_request::text,0));
  SELECT * INTO r FROM app.workflow_runs WHERE version_id=p_version AND request_key=p_request;
  IF FOUND THEN
    IF ROW(r.input_artifact_id,r.policy_version_id,r.priority,r.data_origin,r.condition_id,r.trial_no)
      IS DISTINCT FROM ROW(p_input,p_policy,p_priority,p_origin,p_condition,p_trial) THEN
      RAISE EXCEPTION 'Idempotency key already used with a different payload' USING ERRCODE='23514';
    END IF;
    RETURN r.id;
  END IF;
  INSERT INTO app.workflow_runs(version_id,input_artifact_id,policy_version_id,priority,request_key,data_origin,condition_id,trial_no)
    VALUES(p_version,p_input,p_policy,p_priority,p_request,p_origin,p_condition,p_trial)
    ON CONFLICT(version_id,request_key) DO NOTHING RETURNING id INTO result;
  IF result IS NULL THEN
    SELECT * INTO r FROM app.workflow_runs WHERE version_id=p_version AND request_key=p_request;
    IF ROW(r.input_artifact_id,r.policy_version_id,r.priority,r.data_origin,r.condition_id,r.trial_no)
      IS DISTINCT FROM ROW(p_input,p_policy,p_priority,p_origin,p_condition,p_trial) THEN
      RAISE EXCEPTION 'Idempotency key already used with a different payload' USING ERRCODE='23514';
    END IF;
    RETURN r.id;
  END IF;
  INSERT INTO app.node_executions(run_id,node_id) SELECT result,id FROM app.workflow_nodes WHERE version_id=p_version;
  RETURN result;
END $$;

CREATE FUNCTION guard_execution() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
DECLARE v uuid;
BEGIN
  SELECT version_id INTO v FROM app.workflow_runs WHERE id=NEW.run_id FOR UPDATE;
  IF TG_OP='INSERT' AND NEW.status<>'pending' THEN RAISE EXCEPTION 'Create nodes in pending state' USING ERRCODE='23514'; END IF;
  IF NOT EXISTS (SELECT FROM app.workflow_nodes WHERE id=NEW.node_id AND version_id=v) THEN
    RAISE EXCEPTION 'Node execution belongs to another graph version' USING ERRCODE='23514';
  END IF;
  IF TG_OP='UPDATE' THEN
    IF ROW(NEW.id,NEW.run_id,NEW.node_id) IS DISTINCT FROM ROW(OLD.id,OLD.run_id,OLD.node_id)
      OR OLD.status IN ('succeeded','failed','skipped','cancelled') THEN
      RAISE EXCEPTION 'Execution identity/terminal state is immutable' USING ERRCODE='23514';
    END IF;
    IF NEW.status='pending' AND OLD.status<>'pending' THEN RAISE EXCEPTION 'Execution cannot go backwards' USING ERRCODE='23514'; END IF;
    IF NEW.status='succeeded' AND NOT EXISTS (SELECT FROM app.task_attempts a JOIN app.selection_decisions d ON d.id=a.decision_id
      WHERE d.execution_id=NEW.id AND a.status='succeeded') THEN
      RAISE EXCEPTION 'Successful node needs a successful attempt' USING ERRCODE='23514';
    END IF;
  END IF;
  IF EXISTS (SELECT FROM app.workflow_runs WHERE id=NEW.run_id AND status IN ('succeeded','failed','cancelled')) THEN
    RAISE EXCEPTION 'Cannot change executions of a terminal run' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER execution_guard BEFORE INSERT OR UPDATE ON node_executions FOR EACH ROW EXECUTE FUNCTION guard_execution();

CREATE FUNCTION guard_decision() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    IF OLD.sealed_at IS NOT NULL THEN RAISE EXCEPTION 'Sealed decision is immutable' USING ERRCODE='23514'; END IF;
    RETURN OLD;
  END IF;
  IF TG_OP='UPDATE' AND (OLD.sealed_at IS NOT NULL OR
    ROW(NEW.id,NEW.execution_id,NEW.attempt_no,NEW.created_at) IS DISTINCT FROM ROW(OLD.id,OLD.execution_id,OLD.attempt_no,OLD.created_at)) THEN
    RAISE EXCEPTION 'Sealed decision/decision identity is immutable' USING ERRCODE='23514';
  END IF;
  PERFORM 1 FROM app.workflow_runs r JOIN app.node_executions e ON e.run_id=r.id
    WHERE e.id=NEW.execution_id AND r.status IN ('accepted','running') AND e.status IN ('pending','running') FOR UPDATE OF r,e;
  IF NOT FOUND THEN RAISE EXCEPTION 'Decision needs an active run and node' USING ERRCODE='23514'; END IF;
  IF NEW.sealed_at IS NOT NULL THEN
    IF NOT EXISTS (SELECT FROM app.decision_candidates WHERE decision_id=NEW.id) THEN
      RAISE EXCEPTION 'Decision needs candidate evidence' USING ERRCODE='23514';
    END IF;
    IF NEW.selected_candidate_id IS NOT NULL AND NOT EXISTS
      (SELECT FROM app.decision_candidates WHERE id=NEW.selected_candidate_id AND decision_id=NEW.id AND eligible) THEN
      RAISE EXCEPTION 'Chosen candidate must belong to the decision and be eligible' USING ERRCODE='23514';
    END IF;
    IF NEW.selected_candidate_id IS NULL AND EXISTS (SELECT FROM app.decision_candidates WHERE decision_id=NEW.id AND eligible) THEN
      RAISE EXCEPTION 'A no-eligible decision cannot conceal eligible candidates' USING ERRCODE='23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER decision_guard BEFORE INSERT OR UPDATE OR DELETE ON selection_decisions FOR EACH ROW EXECUTE FUNCTION guard_decision();

CREATE FUNCTION guard_candidate() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
DECLARE d uuid; sealed timestamptz;
BEGIN
  IF TG_OP='UPDATE' AND ROW(NEW.id,NEW.decision_id) IS DISTINCT FROM ROW(OLD.id,OLD.decision_id) THEN
    RAISE EXCEPTION 'Candidate identity is immutable' USING ERRCODE='23514';
  END IF;
  d:=CASE WHEN TG_OP='DELETE' THEN OLD.decision_id ELSE NEW.decision_id END;
  SELECT sealed_at INTO sealed FROM app.selection_decisions WHERE id=d FOR UPDATE;
  IF sealed IS NOT NULL THEN RAISE EXCEPTION 'Sealed candidates are immutable' USING ERRCODE='23514'; END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END $$;
CREATE TRIGGER candidate_guard BEFORE INSERT OR UPDATE OR DELETE ON decision_candidates FOR EACH ROW EXECUTE FUNCTION guard_candidate();

CREATE FUNCTION guard_evidence() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
DECLARE did uuid; sealed timestamptz; cutoff timestamptz; origin text; env text; op uuid;
BEGIN
  IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Evidence links are append-only' USING ERRCODE='23514'; END IF;
  SELECT c.decision_id,rc.environment INTO did,env FROM app.decision_candidates c
    JOIN app.runtime_configurations rc ON rc.id=c.runtime_configuration_id WHERE c.id=NEW.candidate_id;
  SELECT d.sealed_at,d.created_at,r.data_origin,n.operation_version_id INTO sealed,cutoff,origin,op
    FROM app.selection_decisions d JOIN app.node_executions e ON e.id=d.execution_id
    JOIN app.workflow_runs r ON r.id=e.run_id JOIN app.workflow_nodes n ON n.id=e.node_id WHERE d.id=did FOR UPDATE OF d;
  IF sealed IS NOT NULL THEN RAISE EXCEPTION 'Sealed evidence is immutable' USING ERRCODE='23514'; END IF;
  IF NOT EXISTS (SELECT FROM app.workflow_runs r JOIN app.experiment_conditions c ON c.id=r.condition_id
    WHERE r.id=NEW.calibration_run_id AND c.dataset_split='calibration' AND c.mode=env||'_only'
      AND r.status='succeeded' AND r.finished_at<=cutoff AND r.data_origin=origin
      AND EXISTS (SELECT FROM app.workflow_nodes WHERE version_id=r.version_id AND operation_version_id=op)) THEN
    RAISE EXCEPTION 'Evidence must be an earlier successful calibration run for this environment and operation' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER evidence_guard BEFORE INSERT OR UPDATE OR DELETE ON candidate_evidence_links FOR EACH ROW EXECUTE FUNCTION guard_evidence();

CREATE FUNCTION guard_attempt() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
DECLARE sealed timestamptz; choice uuid; e uuid; runstate text; nodestate text;
BEGIN
  SELECT d.sealed_at,d.selected_candidate_id,d.execution_id INTO sealed,choice,e FROM app.selection_decisions d WHERE d.id=NEW.decision_id FOR SHARE;
  IF sealed IS NULL OR choice IS NULL OR NEW.queued_at<sealed THEN
    RAISE EXCEPTION 'Dispatch requires a previously sealed eligible choice' USING ERRCODE='23514';
  END IF;
  SELECT r.status,n.status INTO runstate,nodestate FROM app.node_executions n JOIN app.workflow_runs r ON r.id=n.run_id WHERE n.id=e FOR UPDATE OF r,n;
  IF runstate NOT IN ('accepted','running') OR nodestate NOT IN ('pending','running') THEN
    RAISE EXCEPTION 'Attempt needs an active run and node' USING ERRCODE='23514';
  END IF;
  IF EXISTS (SELECT FROM app.task_attempts a JOIN app.selection_decisions d ON d.id=a.decision_id
    WHERE d.execution_id=e AND a.id<>NEW.id AND a.status IN ('queued','running','succeeded')) THEN
    RAISE EXCEPTION 'Another attempt is active or already succeeded for this node' USING ERRCODE='23514';
  END IF;
  IF TG_OP='INSERT' AND NEW.status<>'queued' THEN
    RAISE EXCEPTION 'Create attempts in queued state' USING ERRCODE='23514';
  END IF;
  IF TG_OP='UPDATE' THEN
    IF OLD.status IN ('succeeded','failed','cancelled') OR ROW(NEW.id,NEW.decision_id,NEW.queued_at)
      IS DISTINCT FROM ROW(OLD.id,OLD.decision_id,OLD.queued_at) THEN
      RAISE EXCEPTION 'Terminal attempt/attempt identity is immutable' USING ERRCODE='23514';
    END IF;
    IF (OLD.started_at IS NOT NULL AND NEW.started_at IS DISTINCT FROM OLD.started_at)
      OR (OLD.dispatch_reference IS NOT NULL AND NEW.dispatch_reference IS DISTINCT FROM OLD.dispatch_reference)
      OR (OLD.status='running' AND NEW.status='queued') THEN
      RAISE EXCEPTION 'Attempt cannot rewrite observed dispatch/start or go backwards' USING ERRCODE='23514';
    END IF;
  END IF;
  IF NEW.status IN ('running','succeeded') AND NEW.dispatch_reference IS NULL THEN
    RAISE EXCEPTION 'Started attempt needs an external dispatch reference' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER attempt_guard BEFORE INSERT OR UPDATE ON task_attempts FOR EACH ROW EXECUTE FUNCTION guard_attempt();

CREATE FUNCTION guard_task_artifact() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
DECLARE owner uuid; artowner uuid; file_row app.artifacts%ROWTYPE; queued timestamptz;
BEGIN
  SELECT w.owner_id INTO owner FROM app.task_attempts a JOIN app.selection_decisions d ON d.id=a.decision_id
    JOIN app.node_executions e ON e.id=d.execution_id JOIN app.workflow_runs r ON r.id=e.run_id
    JOIN app.workflow_versions v ON v.id=r.version_id JOIN app.workflows w ON w.id=v.workflow_id WHERE a.id=NEW.attempt_id;
  SELECT * INTO file_row FROM app.artifacts WHERE id=NEW.artifact_id FOR SHARE;
  artowner:=file_row.owner_id;
  IF owner IS DISTINCT FROM artowner THEN RAISE EXCEPTION 'Cross-owner task artifact' USING ERRCODE='23514'; END IF;
  SELECT queued_at INTO queued FROM app.task_attempts WHERE id=NEW.attempt_id;
  IF NEW.direction='output' AND (file_row.created_at<queued OR file_row.state<>'complete') THEN
    RAISE EXCEPTION 'Output must be a complete artifact created for this attempt' USING ERRCODE='23514';
  END IF;
  IF NEW.direction='input' AND (file_row.state<>'complete' OR file_row.expires_at<=clock_timestamp()) THEN
    RAISE EXCEPTION 'Input artifact is unavailable' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER task_artifact_guard BEFORE INSERT ON task_artifacts FOR EACH ROW EXECUTE FUNCTION guard_task_artifact();
CREATE TRIGGER task_artifact_immutable BEFORE UPDATE OR DELETE ON task_artifacts FOR EACH ROW EXECUTE FUNCTION reject_mutation();

CREATE FUNCTION guard_result() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
BEGIN
  PERFORM 1 FROM app.workflow_runs WHERE id=NEW.run_id FOR UPDATE;
  IF NOT EXISTS (SELECT FROM app.task_attempts a JOIN app.selection_decisions d ON d.id=a.decision_id
    JOIN app.node_executions e ON e.id=d.execution_id JOIN app.task_artifacts ta ON ta.attempt_id=a.id
    JOIN app.artifacts art ON art.id=ta.artifact_id WHERE a.id=NEW.source_attempt_id AND e.run_id=NEW.run_id
      AND a.status='succeeded' AND ta.direction='output' AND ta.artifact_id=NEW.artifact_id AND art.state='complete') THEN
    RAISE EXCEPTION 'Result needs an output of a successful attempt in the same run' USING ERRCODE='23514';
  END IF;
  IF EXISTS (SELECT FROM app.workflow_runs WHERE id=NEW.run_id AND status IN ('succeeded','failed','cancelled')) THEN
    RAISE EXCEPTION 'Cannot append results after run completion' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER result_guard BEFORE INSERT ON run_results FOR EACH ROW EXECUTE FUNCTION guard_result();
CREATE TRIGGER result_immutable BEFORE UPDATE OR DELETE ON run_results FOR EACH ROW EXECUTE FUNCTION reject_mutation();

CREATE FUNCTION guard_measurement() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,app AS $$
BEGIN
  IF TG_TABLE_NAME='task_measurements' THEN
    IF NOT EXISTS (SELECT FROM app.task_attempts WHERE id=NEW.attempt_id AND status IN ('succeeded','failed','cancelled')) THEN
      RAISE EXCEPTION 'Task measurement needs a terminal attempt' USING ERRCODE='23514';
    END IF;
  ELSE
    IF NOT EXISTS (SELECT FROM app.workflow_runs WHERE id=NEW.run_id AND status IN ('succeeded','failed','cancelled')) THEN
      RAISE EXCEPTION 'Run measurement needs a terminal run' USING ERRCODE='23514';
    END IF;
    IF TG_TABLE_NAME='run_verifications' THEN
      IF NEW.outcome='passed' AND NOT EXISTS (SELECT FROM app.workflow_runs WHERE id=NEW.run_id AND status='succeeded') THEN
        RAISE EXCEPTION 'Correctness pass needs a successful run' USING ERRCODE='23514';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER task_measurement_guard BEFORE INSERT ON task_measurements FOR EACH ROW EXECUTE FUNCTION guard_measurement();
CREATE TRIGGER run_measurement_guard BEFORE INSERT ON run_measurements FOR EACH ROW EXECUTE FUNCTION guard_measurement();

INSERT INTO schema_migrations VALUES(2,'Publication, immutable snapshots, ownership, dispatch and transactions',DEFAULT);
COMMIT;
