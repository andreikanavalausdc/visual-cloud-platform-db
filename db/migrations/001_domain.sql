\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE vcp_admin;
SET LOCAL search_path=app,pg_catalog;
CREATE TABLE schema_migrations (
  version integer PRIMARY KEY,
  description text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL UNIQUE CHECK (email=lower(email) AND email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  display_name text NOT NULL CHECK (length(btrim(display_name)) BETWEEN 1 AND 100),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE user_credentials (
  user_id uuid PRIMARY KEY REFERENCES users(id),
  password_hash text NOT NULL CHECK (password_hash ~ '^\$pbkdf2-sha256\$600000\$[A-Za-z0-9+/]{22}==\$[A-Za-z0-9+/]{43}=$'),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE operation_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL,
  version integer NOT NULL CHECK (version>0),
  input_kind text NOT NULL CHECK (input_kind IN ('csv','json','image')),
  output_kind text NOT NULL CHECK (output_kind IN ('csv','json','image')),
  parameter_contract jsonb NOT NULL CHECK (jsonb_typeof(parameter_contract)='object'),
  description text NOT NULL,
  UNIQUE(code,version)
);
CREATE TABLE workflows (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES users(id),
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  archived_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (archived_at IS NULL OR archived_at>=created_at)
);
CREATE TABLE workflow_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workflow_id uuid NOT NULL REFERENCES workflows(id),
  version_no integer NOT NULL CHECK (version_no>0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  published_at timestamptz,
  UNIQUE(workflow_id,version_no),
  CHECK (published_at IS NULL OR published_at>=created_at)
);
CREATE TABLE workflow_nodes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id uuid NOT NULL REFERENCES workflow_versions(id),
  node_key text NOT NULL CHECK (length(btrim(node_key)) BETWEEN 1 AND 80),
  operation_version_id uuid NOT NULL REFERENCES operation_versions(id),
  parameters jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(parameters)='object'),
  position_x numeric(10,2) NOT NULL DEFAULT 0,
  position_y numeric(10,2) NOT NULL DEFAULT 0,
  UNIQUE(version_id,node_key),
  UNIQUE(version_id,id)
);
CREATE TABLE workflow_edges (
  version_id uuid NOT NULL REFERENCES workflow_versions(id),
  source_node_id uuid NOT NULL,
  target_node_id uuid NOT NULL,
  PRIMARY KEY(version_id,source_node_id,target_node_id),
  FOREIGN KEY(version_id,source_node_id) REFERENCES workflow_nodes(version_id,id),
  FOREIGN KEY(version_id,target_node_id) REFERENCES workflow_nodes(version_id,id),
  CHECK (source_node_id<>target_node_id)
);
CREATE TABLE artifacts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES users(id),
  storage_key text NOT NULL UNIQUE CHECK (length(btrim(storage_key))>0),
  original_name text NOT NULL CHECK (length(btrim(original_name)) BETWEEN 1 AND 255),
  media_kind text NOT NULL CHECK (media_kind IN ('csv','json','image')),
  size_bytes bigint NOT NULL CHECK (size_bytes BETWEEN 0 AND 10485760),
  decoded_pixels bigint CHECK (decoded_pixels BETWEEN 1 AND 20000000),
  sha256 text CHECK (sha256 ~ '^[a-f0-9]{64}$'),
  state text NOT NULL CHECK (state IN ('pending','complete','expired','deleted')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz,
  CHECK (expires_at IS NULL OR expires_at>created_at),
  CHECK (media_kind='image' OR decoded_pixels IS NULL),
  CHECK (state<>'complete' OR (sha256 IS NOT NULL AND (media_kind<>'image' OR decoded_pixels IS NOT NULL)))
);
CREATE TABLE runtime_configurations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  environment text NOT NULL CHECK (environment IN ('worker','lambda','fargate')),
  version_no integer NOT NULL CHECK (version_no>0),
  region text NOT NULL CHECK (length(btrim(region))>0),
  execution_model text NOT NULL,
  cpu_units integer NOT NULL CHECK (cpu_units>0),
  memory_mib integer NOT NULL CHECK (memory_mib>0),
  settings jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(settings)='object'),
  UNIQUE(environment,version_no)
);
CREATE TABLE selection_policy_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL,
  version_no integer NOT NULL CHECK (version_no>0),
  definition jsonb NOT NULL CHECK (jsonb_typeof(definition)='object'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(code,version_no)
);
CREATE TABLE cost_model_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL,
  version_no integer NOT NULL CHECK (version_no>0),
  currency text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  rate_date date NOT NULL,
  accounting_scope text NOT NULL CHECK (length(btrim(accounting_scope))>0),
  rates jsonb NOT NULL CHECK (jsonb_typeof(rates)='object'),
  UNIQUE(code,version_no)
);
CREATE TABLE experiment_conditions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scenario text NOT NULL CHECK (scenario IN ('csv','image')),
  input_volume text NOT NULL CHECK (input_volume IN ('small','large')),
  arrival_pattern text NOT NULL CHECK (arrival_pattern IN ('isolated','grouped')),
  mode text NOT NULL CHECK (mode IN ('worker_only','lambda_only','fargate_only','auto_balanced','auto_fastest','auto_cheapest')),
  dataset_split text NOT NULL CHECK (dataset_split IN ('calibration','evaluation')),
  fixture_key text NOT NULL,
  protocol_version text NOT NULL,
  UNIQUE(scenario,input_volume,arrival_pattern,mode,dataset_split,fixture_key,protocol_version)
);
CREATE TABLE workflow_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id uuid NOT NULL REFERENCES workflow_versions(id),
  input_artifact_id uuid NOT NULL REFERENCES artifacts(id),
  policy_version_id uuid NOT NULL REFERENCES selection_policy_versions(id),
  priority text NOT NULL CHECK (priority IN ('balanced','fastest','cheapest')),
  condition_id uuid REFERENCES experiment_conditions(id),
  trial_no integer CHECK (trial_no>0),
  data_origin text NOT NULL CHECK (data_origin IN ('synthetic','observed')),
  request_key uuid NOT NULL,
  status text NOT NULL DEFAULT 'accepted' CHECK (status IN ('accepted','running','succeeded','failed','cancelled')),
  accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  started_at timestamptz,
  finished_at timestamptz,
  error_code text,
  UNIQUE(version_id,request_key),
  UNIQUE(condition_id,trial_no),
  CHECK ((condition_id IS NULL)=(trial_no IS NULL)),
  CHECK (started_at IS NULL OR started_at>=accepted_at),
  CHECK (finished_at IS NULL OR finished_at>=coalesce(started_at,accepted_at)),
  CHECK ((status IN ('succeeded','failed','cancelled'))=(finished_at IS NOT NULL)),
  CHECK (status NOT IN ('running','succeeded') OR started_at IS NOT NULL),
  CHECK (status<>'failed' OR error_code IS NOT NULL)
);
CREATE TABLE node_executions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id uuid NOT NULL REFERENCES workflow_runs(id),
  node_id uuid NOT NULL REFERENCES workflow_nodes(id),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','running','succeeded','failed','skipped','cancelled')),
  UNIQUE(run_id,node_id)
);
CREATE TABLE selection_decisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  execution_id uuid NOT NULL REFERENCES node_executions(id),
  attempt_no integer NOT NULL CHECK (attempt_no>0),
  selected_candidate_id uuid,
  is_fallback boolean NOT NULL DEFAULT false,
  explanation text NOT NULL CHECK (length(btrim(explanation))>0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  sealed_at timestamptz,
  UNIQUE(execution_id,attempt_no),
  CHECK (sealed_at IS NULL OR sealed_at>=created_at),
  CHECK (NOT is_fallback OR selected_candidate_id IS NOT NULL)
);
CREATE TABLE decision_candidates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  decision_id uuid NOT NULL REFERENCES selection_decisions(id),
  runtime_configuration_id uuid NOT NULL REFERENCES runtime_configurations(id),
  eligible boolean NOT NULL,
  exclusion_reason text,
  predicted_ms bigint CHECK (predicted_ms>=0),
  predicted_cost numeric(20,10) CHECK (predicted_cost>=0 AND predicted_cost<'Infinity'::numeric),
  cost_model_id uuid REFERENCES cost_model_versions(id),
  uncertainty_note text,
  UNIQUE(decision_id,runtime_configuration_id),
  UNIQUE(decision_id,id),
  CHECK ((eligible AND exclusion_reason IS NULL) OR (NOT eligible AND exclusion_reason IS NOT NULL AND length(btrim(exclusion_reason))>0)),
  CHECK (predicted_cost IS NULL OR cost_model_id IS NOT NULL)
);
ALTER TABLE selection_decisions ADD CONSTRAINT selected_candidate_same_decision
  FOREIGN KEY(id,selected_candidate_id) REFERENCES decision_candidates(decision_id,id);
CREATE TABLE candidate_evidence_links (
  candidate_id uuid NOT NULL REFERENCES decision_candidates(id),
  calibration_run_id uuid NOT NULL REFERENCES workflow_runs(id),
  PRIMARY KEY(candidate_id,calibration_run_id)
);
CREATE TABLE task_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  decision_id uuid NOT NULL UNIQUE REFERENCES selection_decisions(id),
  dispatch_reference text UNIQUE,
  status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','succeeded','failed','cancelled')),
  queued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  started_at timestamptz,
  finished_at timestamptz,
  error_code text,
  safe_error_message text,
  CHECK (started_at IS NULL OR started_at>=queued_at),
  CHECK (finished_at IS NULL OR finished_at>=coalesce(started_at,queued_at)),
  CHECK ((status IN ('succeeded','failed','cancelled'))=(finished_at IS NOT NULL)),
  CHECK (status NOT IN ('running','succeeded') OR started_at IS NOT NULL),
  CHECK (status<>'failed' OR error_code IS NOT NULL)
);
CREATE TABLE task_artifacts (
  attempt_id uuid NOT NULL REFERENCES task_attempts(id),
  artifact_id uuid NOT NULL REFERENCES artifacts(id),
  direction text NOT NULL CHECK (direction IN ('input','output')),
  port_name text NOT NULL CHECK (length(btrim(port_name))>0),
  PRIMARY KEY(attempt_id,direction,port_name)
);
CREATE TABLE run_results (
  run_id uuid NOT NULL REFERENCES workflow_runs(id),
  artifact_id uuid NOT NULL REFERENCES artifacts(id),
  source_attempt_id uuid NOT NULL REFERENCES task_attempts(id),
  PRIMARY KEY(run_id,artifact_id)
);
CREATE TABLE task_measurements (
  attempt_id uuid PRIMARY KEY REFERENCES task_attempts(id),
  processing_ms bigint CHECK (processing_ms>=0),
  modeled_cost numeric(20,10) CHECK (modeled_cost>=0 AND modeled_cost<'Infinity'::numeric),
  cost_model_id uuid REFERENCES cost_model_versions(id),
  actual_cpu_seconds numeric(20,6) CHECK (actual_cpu_seconds>=0 AND actual_cpu_seconds<'Infinity'::numeric),
  peak_memory_bytes bigint CHECK (peak_memory_bytes>=0),
  unavailable_reason text,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (modeled_cost IS NULL OR cost_model_id IS NOT NULL),
  CHECK ((processing_ms IS NOT NULL AND modeled_cost IS NOT NULL AND actual_cpu_seconds IS NOT NULL AND peak_memory_bytes IS NOT NULL)
    OR (unavailable_reason IS NOT NULL AND length(btrim(unavailable_reason))>0))
);
CREATE TABLE run_measurements (
  run_id uuid PRIMARY KEY REFERENCES workflow_runs(id),
  end_to_end_ms bigint CHECK (end_to_end_ms>=0),
  modeled_cost numeric(20,10) CHECK (modeled_cost>=0 AND modeled_cost<'Infinity'::numeric),
  cost_model_id uuid REFERENCES cost_model_versions(id),
  observation_window_start timestamptz,
  observation_window_end timestamptz,
  allocated_idle_cost numeric(20,10) CHECK (allocated_idle_cost>=0 AND allocated_idle_cost<'Infinity'::numeric),
  unavailable_reason text,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (modeled_cost IS NULL OR cost_model_id IS NOT NULL),
  CHECK ((observation_window_start IS NULL)=(observation_window_end IS NULL)),
  CHECK (observation_window_end IS NULL OR observation_window_end>observation_window_start),
  CHECK (allocated_idle_cost IS NULL OR (observation_window_start IS NOT NULL AND cost_model_id IS NOT NULL)),
  CHECK ((end_to_end_ms IS NOT NULL AND modeled_cost IS NOT NULL) OR (unavailable_reason IS NOT NULL AND length(btrim(unavailable_reason))>0))
);
INSERT INTO schema_migrations VALUES(1,'Normalized workflow, execution and research domain',DEFAULT);
COMMIT;
