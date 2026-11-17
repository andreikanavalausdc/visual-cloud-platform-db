\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE vcp_admin;
SET LOCAL search_path=app,pg_catalog;
CREATE TABLE run_verifications (
  run_id uuid PRIMARY KEY REFERENCES workflow_runs(id),
  outcome text NOT NULL CHECK (outcome IN ('passed','failed')),
  checker_version text NOT NULL CHECK (length(btrim(checker_version))>0),
  expected_result_key text NOT NULL CHECK (length(btrim(expected_result_key))>0),
  checked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  note text NOT NULL
);
CREATE TRIGGER verification_immutable BEFORE UPDATE OR DELETE ON run_verifications FOR EACH ROW EXECUTE FUNCTION reject_mutation();
CREATE TRIGGER verification_terminal BEFORE INSERT ON run_verifications FOR EACH ROW EXECUTE FUNCTION guard_measurement();

CREATE INDEX workflow_owner_created ON workflows(owner_id,created_at DESC);
CREATE INDEX edge_target ON workflow_edges(version_id,target_node_id);
CREATE INDEX node_operation ON workflow_nodes(operation_version_id);
CREATE INDEX artifact_owner_created ON artifacts(owner_id,created_at DESC);
CREATE INDEX artifact_expiry ON artifacts(expires_at) WHERE state='complete' AND expires_at IS NOT NULL;
CREATE INDEX run_version_accepted ON workflow_runs(version_id,accepted_at DESC);
CREATE INDEX run_input ON workflow_runs(input_artifact_id);
CREATE INDEX run_policy ON workflow_runs(policy_version_id);
CREATE INDEX run_active ON workflow_runs(accepted_at) WHERE status IN ('accepted','running');
CREATE INDEX execution_node ON node_executions(node_id);
CREATE INDEX candidate_runtime ON decision_candidates(runtime_configuration_id);
CREATE INDEX candidate_cost_model ON decision_candidates(cost_model_id);
CREATE INDEX evidence_calibration ON candidate_evidence_links(calibration_run_id);
CREATE INDEX task_artifact_file ON task_artifacts(artifact_id);
CREATE INDEX result_file ON run_results(artifact_id);
CREATE INDEX result_attempt ON run_results(source_attempt_id);

CREATE VIEW v_users_masked AS
  SELECT id,'user-'||left(id::text,8) AS display_label,'[redacted]'::text AS email,is_active FROM users;

CREATE VIEW v_run_summary AS
  SELECT r.id,r.version_id,v.version_no,w.id AS workflow_id,w.owner_id,w.name,r.priority,r.status,
    r.data_origin,r.accepted_at,r.finished_at,m.end_to_end_ms,m.modeled_cost,cm.currency,
    m.unavailable_reason,coalesce(q.outcome,'not_checked') AS verification,
    (SELECT count(*) FROM run_results rr WHERE rr.run_id=r.id) AS output_count
  FROM workflow_runs r JOIN workflow_versions v ON v.id=r.version_id JOIN workflows w ON w.id=v.workflow_id
    LEFT JOIN run_measurements m ON m.run_id=r.id LEFT JOIN cost_model_versions cm ON cm.id=m.cost_model_id
    LEFT JOIN run_verifications q ON q.run_id=r.id;

CREATE VIEW v_result_metadata AS
  SELECT rr.run_id,a.id AS artifact_id,a.original_name,a.media_kind,a.size_bytes,a.state,a.expires_at,
    (a.state='complete' AND (a.expires_at IS NULL OR a.expires_at>current_timestamp)) AS available
  FROM run_results rr JOIN artifacts a ON a.id=rr.artifact_id JOIN workflow_runs r ON r.id=rr.run_id
  WHERE r.status='succeeded';

CREATE VIEW v_research_comparison AS
  SELECT c.scenario,c.input_volume,c.arrival_pattern,c.mode,c.dataset_split,c.fixture_key,c.protocol_version,
    r.data_origin,m.cost_model_id,cm.currency,
    count(*) AS attempts,
    count(*) FILTER (WHERE r.status='succeeded') AS succeeded,
    count(*) FILTER (WHERE r.status='failed') AS failed,
    count(*) FILTER (WHERE r.status='cancelled') AS cancelled,
    count(*) FILTER (WHERE r.status IN ('accepted','running')) AS unfinished,
    count(*) FILTER (WHERE r.status='succeeded' AND q.outcome='passed') AS verified_correct,
    count(*) FILTER (WHERE q.run_id IS NULL) AS unverified,
    count(*) FILTER (WHERE m.end_to_end_ms IS NULL) AS missing_time,
    count(*) FILTER (WHERE m.modeled_cost IS NULL) AS missing_cost,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY m.end_to_end_ms)
      FILTER (WHERE r.status='succeeded' AND q.outcome='passed') AS median_correct_ms,
    avg(m.modeled_cost) FILTER (WHERE r.status='succeeded' AND q.outcome='passed') AS mean_correct_cost
  FROM experiment_conditions c JOIN workflow_runs r ON r.condition_id=c.id
    LEFT JOIN run_measurements m ON m.run_id=r.id LEFT JOIN cost_model_versions cm ON cm.id=m.cost_model_id
    LEFT JOIN run_verifications q ON q.run_id=r.id
  GROUP BY c.scenario,c.input_volume,c.arrival_pattern,c.mode,c.dataset_split,c.fixture_key,c.protocol_version,
    r.data_origin,m.cost_model_id,cm.currency;

INSERT INTO schema_migrations VALUES(3,'Reporting, correctness, masking and query indexes',DEFAULT);
COMMIT;
