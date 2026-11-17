\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE vcp_admin;
REVOKE ALL ON ALL TABLES IN SCHEMA app FROM PUBLIC,vcp_read,vcp_write;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC,vcp_read,vcp_write;
GRANT SELECT ON app.v_users_masked,app.v_run_summary,app.v_result_metadata,app.v_research_comparison TO vcp_read;
GRANT SELECT(id,is_active,created_at) ON app.users TO vcp_write;
GRANT SELECT ON app.operation_versions,app.runtime_configurations,app.selection_policy_versions,
  app.cost_model_versions,app.experiment_conditions TO vcp_write;
GRANT SELECT,INSERT,UPDATE ON app.workflows,app.workflow_versions,app.workflow_nodes,app.workflow_edges,
  app.artifacts,app.workflow_runs,app.node_executions,app.selection_decisions,app.decision_candidates TO vcp_write;
GRANT DELETE ON app.workflow_nodes,app.workflow_edges TO vcp_write;
GRANT SELECT,INSERT ON app.candidate_evidence_links,app.task_artifacts,app.run_results,app.task_measurements,
  app.run_measurements,app.run_verifications TO vcp_write;
GRANT SELECT,INSERT,UPDATE ON app.task_attempts TO vcp_write;
GRANT SELECT ON app.v_run_summary,app.v_result_metadata TO vcp_write;
GRANT EXECUTE ON FUNCTION app.valid_parameters(text,jsonb),
  app.create_run(uuid,uuid,uuid,text,uuid,text,uuid,integer) TO vcp_write;

COMMIT;
