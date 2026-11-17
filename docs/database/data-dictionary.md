# PostgreSQL data dictionary

Generated from the installed `app` schema by `scripts/export_database_docs.py`. Business meanings are maintained in that script. SQL constraints below are the actual database definitions.

The database has 24 tables including migration history, 4 views, and typed relational links. All timestamps use `timestamptz`; no file body is stored here.

## artifacts

Owned file metadata and private external storage locator; no file body.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| id | uuid | NO | gen_random_uuid() | Stable generated UUID; never reused. |
| owner_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| storage_key | text | NO | — | Private opaque file locator; never a secret or signed download URL. |
| original_name | text | NO | — | Safe metadata filename; application still sanitizes it for downloads. |
| media_kind | text | NO | — | CSV/JSON/image classification. |
| size_bytes | bigint | NO | — | Stored file byte size, 0..10485760. |
| decoded_pixels | bigint | YES | — | Decoded image pixel count, 1..20000000; NULL for non-images. |
| sha256 | text | YES | — | Lowercase content checksum, never a password hashing method. |
| state | text | NO | — | File lifecycle: pending, complete, expired, deleted. |
| created_at | timestamp with time zone | NO | clock_timestamp() | Record creation time; timestamptz is an instant, display timezone is a client setting. |
| expires_at | timestamp with time zone | YES | — | Optional availability deadline; background physical deletion is future work. |

Constraints:

- `artifacts_check`: `CHECK (((expires_at IS NULL) OR (expires_at > created_at)))`.
- `artifacts_check1`: `CHECK (((media_kind = 'image'::text) OR (decoded_pixels IS NULL)))`.
- `artifacts_check2`: `CHECK (((state <> 'complete'::text) OR ((sha256 IS NOT NULL) AND ((media_kind <> 'image'::text) OR (decoded_pixels IS NOT NULL)))))`.
- `artifacts_decoded_pixels_check`: `CHECK (((decoded_pixels >= 1) AND (decoded_pixels <= 20000000)))`.
- `artifacts_media_kind_check`: `CHECK ((media_kind = ANY (ARRAY['csv'::text, 'json'::text, 'image'::text])))`.
- `artifacts_original_name_check`: `CHECK (((length(btrim(original_name)) >= 1) AND (length(btrim(original_name)) <= 255)))`.
- `artifacts_owner_id_fkey`: `FOREIGN KEY (owner_id) REFERENCES app.users(id)`.
- `artifacts_pkey`: `PRIMARY KEY (id)`.
- `artifacts_sha256_check`: `CHECK ((sha256 ~ '^[a-f0-9]{64}$'::text))`.
- `artifacts_size_bytes_check`: `CHECK (((size_bytes >= 0) AND (size_bytes <= 10485760)))`.
- `artifacts_state_check`: `CHECK ((state = ANY (ARRAY['pending'::text, 'complete'::text, 'expired'::text, 'deleted'::text])))`.
- `artifacts_storage_key_check`: `CHECK ((length(btrim(storage_key)) > 0))`.
- `artifacts_storage_key_key`: `UNIQUE (storage_key)`.

## candidate_evidence_links

Many-to-many links from candidates to earlier successful calibration runs.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| candidate_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| calibration_run_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |

Constraints:

- `candidate_evidence_links_calibration_run_id_fkey`: `FOREIGN KEY (calibration_run_id) REFERENCES app.workflow_runs(id)`.
- `candidate_evidence_links_candidate_id_fkey`: `FOREIGN KEY (candidate_id) REFERENCES app.decision_candidates(id)`.
- `candidate_evidence_links_pkey`: `PRIMARY KEY (candidate_id, calibration_run_id)`.

## cost_model_versions

Immutable currency, rate date and declared accounting scope.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| id | uuid | NO | gen_random_uuid() | Stable generated UUID; never reused. |
| code | text | NO | — | Stable semantic identifier, not a display label. |
| version_no | integer | NO | — | Positive version number within its parent/code/environment. |
| currency | text | NO | — | Three-letter uppercase currency identifier. |
| rate_date | date | NO | — | Date to which the versioned rates apply. |
| accounting_scope | text | NO | — | Included/excluded modeled cost items; hosting and invoices are separate. |
| rates | jsonb | NO | — | Structured versioned rates; demo values are synthetic. |

Constraints:

- `cost_model_versions_accounting_scope_check`: `CHECK ((length(btrim(accounting_scope)) > 0))`.
- `cost_model_versions_code_version_no_key`: `UNIQUE (code, version_no)`.
- `cost_model_versions_currency_check`: `CHECK ((currency ~ '^[A-Z]{3}$'::text))`.
- `cost_model_versions_pkey`: `PRIMARY KEY (id)`.
- `cost_model_versions_rates_check`: `CHECK ((jsonb_typeof(rates) = 'object'::text))`.
- `cost_model_versions_version_no_check`: `CHECK ((version_no > 0))`.

## decision_candidates

Eligibility, exclusions, forecasts and immutable runtime candidate identity.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| id | uuid | NO | gen_random_uuid() | Stable generated UUID; never reused. |
| decision_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| runtime_configuration_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| eligible | boolean | NO | — | Technical eligibility flag; false requires an exclusion reason. |
| exclusion_reason | text | YES | — | Nonblank reason for an ineligible candidate; NULL for eligible. |
| predicted_ms | bigint | YES | — | Pre-run duration forecast in milliseconds; NULL if not available. |
| predicted_cost | numeric(20,10) | YES | — | Pre-run nominal forecast in the referenced cost model currency. |
| cost_model_id | uuid | YES | — | Relational identifier; target and scope are specified by the foreign keys below. |
| uncertainty_note | text | YES | — | Qualitative uncertainty, without an invented numeric error bound. |

Constraints:

- `decision_candidates_check`: `CHECK (((eligible AND (exclusion_reason IS NULL)) OR ((NOT eligible) AND (exclusion_reason IS NOT NULL) AND (length(btrim(exclusion_reason)) > 0))))`.
- `decision_candidates_check1`: `CHECK (((predicted_cost IS NULL) OR (cost_model_id IS NOT NULL)))`.
- `decision_candidates_cost_model_id_fkey`: `FOREIGN KEY (cost_model_id) REFERENCES app.cost_model_versions(id)`.
- `decision_candidates_decision_id_fkey`: `FOREIGN KEY (decision_id) REFERENCES app.selection_decisions(id)`.
- `decision_candidates_decision_id_id_key`: `UNIQUE (decision_id, id)`.
- `decision_candidates_decision_id_runtime_configuration_id_key`: `UNIQUE (decision_id, runtime_configuration_id)`.
- `decision_candidates_pkey`: `PRIMARY KEY (id)`.
- `decision_candidates_predicted_cost_check`: `CHECK (((predicted_cost >= (0)::numeric) AND (predicted_cost < 'Infinity'::numeric)))`.
- `decision_candidates_predicted_ms_check`: `CHECK ((predicted_ms >= 0))`.
- `decision_candidates_runtime_configuration_id_fkey`: `FOREIGN KEY (runtime_configuration_id) REFERENCES app.runtime_configurations(id)`.

## experiment_conditions

One frozen research condition; repetitions are separate runs.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| id | uuid | NO | gen_random_uuid() | Stable generated UUID; never reused. |
| scenario | text | NO | — | CSV or image research workload. |
| input_volume | text | NO | — | Named small/large size band; exact fixture defines its bytes. |
| arrival_pattern | text | NO | — | Isolated or grouped arrival protocol. |
| mode | text | NO | — | Three fixed research baselines or three automatic priorities. |
| dataset_split | text | NO | — | Calibration or held-out evaluation. Evaluation cannot be cited as calibration evidence. |
| fixture_key | text | NO | — | Versioned dataset reference, not file bytes. |
| protocol_version | text | NO | — | Frozen experiment protocol identifier. |

Constraints:

- `experiment_conditions_arrival_pattern_check`: `CHECK ((arrival_pattern = ANY (ARRAY['isolated'::text, 'grouped'::text])))`.
- `experiment_conditions_dataset_split_check`: `CHECK ((dataset_split = ANY (ARRAY['calibration'::text, 'evaluation'::text])))`.
- `experiment_conditions_input_volume_check`: `CHECK ((input_volume = ANY (ARRAY['small'::text, 'large'::text])))`.
- `experiment_conditions_mode_check`: `CHECK ((mode = ANY (ARRAY['worker_only'::text, 'lambda_only'::text, 'fargate_only'::text, 'auto_balanced'::text, 'auto_fastest'::text, 'auto_cheapest'::text])))`.
- `experiment_conditions_pkey`: `PRIMARY KEY (id)`.
- `experiment_conditions_scenario_check`: `CHECK ((scenario = ANY (ARRAY['csv'::text, 'image'::text])))`.
- `experiment_conditions_scenario_input_volume_arrival_pattern_key`: `UNIQUE (scenario, input_volume, arrival_pattern, mode, dataset_split, fixture_key, protocol_version)`.

## node_executions

One logical execution of a saved node in a run.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| id | uuid | NO | gen_random_uuid() | Stable generated UUID; never reused. |
| run_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| node_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| status | text | NO | 'pending'::text | Lifecycle value constrained by table-specific CHECK and transition triggers. |

Constraints:

- `node_executions_node_id_fkey`: `FOREIGN KEY (node_id) REFERENCES app.workflow_nodes(id)`.
- `node_executions_pkey`: `PRIMARY KEY (id)`.
- `node_executions_run_id_fkey`: `FOREIGN KEY (run_id) REFERENCES app.workflow_runs(id)`.
- `node_executions_run_id_node_id_key`: `UNIQUE (run_id, node_id)`.
- `node_executions_status_check`: `CHECK ((status = ANY (ARRAY['pending'::text, 'running'::text, 'succeeded'::text, 'failed'::text, 'skipped'::text, 'cancelled'::text])))`.

## operation_versions

Immutable operation contract and typed input/output formats.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| id | uuid | NO | gen_random_uuid() | Stable generated UUID; never reused. |
| code | text | NO | — | Stable semantic identifier, not a display label. |
| version | integer | NO | — | Applied schema version or immutable operation version number, according to table. |
| input_kind | text | NO | — | Declared input format. |
| output_kind | text | NO | — | Declared output format. |
| parameter_contract | jsonb | NO | — | Documented operation-specific JSON contract; validated CSV subset is implemented in valid_parameters. |
| description | text | NO | — | Human-readable purpose; no secrets. |

Constraints:

- `operation_versions_code_version_key`: `UNIQUE (code, version)`.
- `operation_versions_input_kind_check`: `CHECK ((input_kind = ANY (ARRAY['csv'::text, 'json'::text, 'image'::text])))`.
- `operation_versions_output_kind_check`: `CHECK ((output_kind = ANY (ARRAY['csv'::text, 'json'::text, 'image'::text])))`.
- `operation_versions_parameter_contract_check`: `CHECK ((jsonb_typeof(parameter_contract) = 'object'::text))`.
- `operation_versions_pkey`: `PRIMARY KEY (id)`.
- `operation_versions_version_check`: `CHECK ((version > 0))`.

## run_measurements

End-to-end time and nominal modeled cost with optional worker idle allocation.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| run_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| end_to_end_ms | bigint | YES | — | Whole workflow time from accepted launch to ready result, in milliseconds. |
| modeled_cost | numeric(20,10) | YES | — | Finite, nonnegative modeled amount in the referenced cost model; not an invoice. |
| cost_model_id | uuid | YES | — | Relational identifier; target and scope are specified by the foreign keys below. |
| observation_window_start | timestamp with time zone | YES | — | Start of explicit worker capacity/idle accounting period. |
| observation_window_end | timestamp with time zone | YES | — | End of that period; greater than its start. |
| allocated_idle_cost | numeric(20,10) | YES | — | Idle-capacity cost allocated to this run; same model/currency, explicit period required. |
| unavailable_reason | text | YES | — | Required when the table-defined telemetry set is incomplete. |
| recorded_at | timestamp with time zone | NO | clock_timestamp() | Telemetry snapshot recording instant. |

Constraints:

- `run_measurements_allocated_idle_cost_check`: `CHECK (((allocated_idle_cost >= (0)::numeric) AND (allocated_idle_cost < 'Infinity'::numeric)))`.
- `run_measurements_check`: `CHECK (((modeled_cost IS NULL) OR (cost_model_id IS NOT NULL)))`.
- `run_measurements_check1`: `CHECK (((observation_window_start IS NULL) = (observation_window_end IS NULL)))`.
- `run_measurements_check2`: `CHECK (((observation_window_end IS NULL) OR (observation_window_end > observation_window_start)))`.
- `run_measurements_check3`: `CHECK (((allocated_idle_cost IS NULL) OR ((observation_window_start IS NOT NULL) AND (cost_model_id IS NOT NULL))))`.
- `run_measurements_check4`: `CHECK ((((end_to_end_ms IS NOT NULL) AND (modeled_cost IS NOT NULL)) OR ((unavailable_reason IS NOT NULL) AND (length(btrim(unavailable_reason)) > 0))))`.
- `run_measurements_cost_model_id_fkey`: `FOREIGN KEY (cost_model_id) REFERENCES app.cost_model_versions(id)`.
- `run_measurements_end_to_end_ms_check`: `CHECK ((end_to_end_ms >= 0))`.
- `run_measurements_modeled_cost_check`: `CHECK (((modeled_cost >= (0)::numeric) AND (modeled_cost < 'Infinity'::numeric)))`.
- `run_measurements_pkey`: `PRIMARY KEY (run_id)`.
- `run_measurements_run_id_fkey`: `FOREIGN KEY (run_id) REFERENCES app.workflow_runs(id)`.

## run_results

Final output bound to a successful attempt in the same run.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| run_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| artifact_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| source_attempt_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |

Constraints:

- `run_results_artifact_id_fkey`: `FOREIGN KEY (artifact_id) REFERENCES app.artifacts(id)`.
- `run_results_pkey`: `PRIMARY KEY (run_id, artifact_id)`.
- `run_results_run_id_fkey`: `FOREIGN KEY (run_id) REFERENCES app.workflow_runs(id)`.
- `run_results_source_attempt_id_fkey`: `FOREIGN KEY (source_attempt_id) REFERENCES app.task_attempts(id)`.

## run_verifications

Explicit correctness evidence independent of runtime success.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| run_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| outcome | text | NO | — | Correctness passed/failed, independently of execution status. |
| checker_version | text | NO | — | Versioned correctness checking method. |
| expected_result_key | text | NO | — | Reference to known expected result/semantic properties. |
| checked_at | timestamp with time zone | NO | clock_timestamp() | Correctness check timestamp. |
| note | text | NO | — | Evidence limitations and explanation; synthetic fixtures explicitly say no processor check was executed. |

Constraints:

- `run_verifications_checker_version_check`: `CHECK ((length(btrim(checker_version)) > 0))`.
- `run_verifications_expected_result_key_check`: `CHECK ((length(btrim(expected_result_key)) > 0))`.
- `run_verifications_outcome_check`: `CHECK ((outcome = ANY (ARRAY['passed'::text, 'failed'::text])))`.
- `run_verifications_pkey`: `PRIMARY KEY (run_id)`.
- `run_verifications_run_id_fkey`: `FOREIGN KEY (run_id) REFERENCES app.workflow_runs(id)`.

## runtime_configurations

Immutable environment/resource configuration; not actual utilization.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| id | uuid | NO | gen_random_uuid() | Stable generated UUID; never reused. |
| environment | text | NO | — | worker, lambda or fargate. |
| version_no | integer | NO | — | Positive version number within its parent/code/environment. |
| region | text | NO | — | Configured region; synthetic-region in fixtures is not deployed. |
| execution_model | text | NO | — | Named invocation/container/process model. |
| cpu_units | integer | NO | — | Configured CPU allocation, not observed usage. |
| memory_mib | integer | NO | — | Configured RAM allocation, not observed usage. |
| settings | jsonb | NO | '{}'::jsonb | Small non-secret environment settings object. |

Constraints:

- `runtime_configurations_cpu_units_check`: `CHECK ((cpu_units > 0))`.
- `runtime_configurations_environment_check`: `CHECK ((environment = ANY (ARRAY['worker'::text, 'lambda'::text, 'fargate'::text])))`.
- `runtime_configurations_environment_version_no_key`: `UNIQUE (environment, version_no)`.
- `runtime_configurations_memory_mib_check`: `CHECK ((memory_mib > 0))`.
- `runtime_configurations_pkey`: `PRIMARY KEY (id)`.
- `runtime_configurations_region_check`: `CHECK ((length(btrim(region)) > 0))`.
- `runtime_configurations_settings_check`: `CHECK ((jsonb_typeof(settings) = 'object'::text))`.
- `runtime_configurations_version_no_check`: `CHECK ((version_no > 0))`.

## schema_migrations

Applied schema versions; source history is kept in Git.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| version | integer | NO | — | Applied schema version or immutable operation version number, according to table. |
| description | text | NO | — | Human-readable purpose; no secrets. |
| applied_at | timestamp with time zone | NO | clock_timestamp() | Migration application instant. |

Constraints:

- `schema_migrations_pkey`: `PRIMARY KEY (version)`.

## selection_decisions

Pre-dispatch choice or no-eligible record; seal before dispatch.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| id | uuid | NO | gen_random_uuid() | Stable generated UUID; never reused. |
| execution_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| attempt_no | integer | NO | — | Positive retry index for a logical node execution. |
| selected_candidate_id | uuid | YES | — | Relational identifier; target and scope are specified by the foreign keys below. |
| is_fallback | boolean | NO | false | Whether the selected eligible candidate is a fallback. |
| explanation | text | NO | — | Readable selection or rejection explanation. |
| created_at | timestamp with time zone | NO | clock_timestamp() | Record creation time; timestamptz is an instant, display timezone is a client setting. |
| sealed_at | timestamp with time zone | YES | — | Seal instant; freezes decision, candidates and evidence links. |

Constraints:

- `selected_candidate_same_decision`: `FOREIGN KEY (id, selected_candidate_id) REFERENCES app.decision_candidates(decision_id, id)`.
- `selection_decisions_attempt_no_check`: `CHECK ((attempt_no > 0))`.
- `selection_decisions_check`: `CHECK (((sealed_at IS NULL) OR (sealed_at >= created_at)))`.
- `selection_decisions_check1`: `CHECK (((NOT is_fallback) OR (selected_candidate_id IS NOT NULL)))`.
- `selection_decisions_execution_id_attempt_no_key`: `UNIQUE (execution_id, attempt_no)`.
- `selection_decisions_execution_id_fkey`: `FOREIGN KEY (execution_id) REFERENCES app.node_executions(id)`.
- `selection_decisions_explanation_check`: `CHECK ((length(btrim(explanation)) > 0))`.
- `selection_decisions_pkey`: `PRIMARY KEY (id)`.

## selection_policy_versions

Immutable selection policy description; no implemented selector is implied.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| id | uuid | NO | gen_random_uuid() | Stable generated UUID; never reused. |
| code | text | NO | — | Stable semantic identifier, not a display label. |
| version_no | integer | NO | — | Positive version number within its parent/code/environment. |
| definition | jsonb | NO | — | Frozen policy description; algorithm calibration remains future work. |
| created_at | timestamp with time zone | NO | clock_timestamp() | Record creation time; timestamptz is an instant, display timezone is a client setting. |

Constraints:

- `selection_policy_versions_code_version_no_key`: `UNIQUE (code, version_no)`.
- `selection_policy_versions_definition_check`: `CHECK ((jsonb_typeof(definition) = 'object'::text))`.
- `selection_policy_versions_pkey`: `PRIMARY KEY (id)`.
- `selection_policy_versions_version_no_check`: `CHECK ((version_no > 0))`.

## task_artifacts

Input/output port binding for an attempt; cannot bind a foreign owner.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| attempt_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| artifact_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| direction | text | NO | — | Input or output binding. |
| port_name | text | NO | — | Operation port name; one artifact per attempt/direction/port. |

Constraints:

- `task_artifacts_artifact_id_fkey`: `FOREIGN KEY (artifact_id) REFERENCES app.artifacts(id)`.
- `task_artifacts_attempt_id_fkey`: `FOREIGN KEY (attempt_id) REFERENCES app.task_attempts(id)`.
- `task_artifacts_direction_check`: `CHECK ((direction = ANY (ARRAY['input'::text, 'output'::text])))`.
- `task_artifacts_pkey`: `PRIMARY KEY (attempt_id, direction, port_name)`.
- `task_artifacts_port_name_check`: `CHECK ((length(btrim(port_name)) > 0))`.

## task_attempts

One dispatch attempt under one sealed decision; retries stay separate.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| id | uuid | NO | gen_random_uuid() | Stable generated UUID; never reused. |
| decision_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| dispatch_reference | text | YES | — | Opaque external execution identity; synthetic:// in fixtures; no credentials. |
| status | text | NO | 'queued'::text | Lifecycle value constrained by table-specific CHECK and transition triggers. |
| queued_at | timestamp with time zone | NO | clock_timestamp() | Durable attempt creation before external dispatch. |
| started_at | timestamp with time zone | YES | — | Observed start instant; immutable once filled. |
| finished_at | timestamp with time zone | YES | — | Observed terminal instant; not earlier than start/acceptance. |
| error_code | text | YES | — | Safe failure category; required for failed run/attempt. |
| safe_error_message | text | YES | — | Sanitized diagnostic text; no raw payload or credentials. |

Constraints:

- `task_attempts_check`: `CHECK (((started_at IS NULL) OR (started_at >= queued_at)))`.
- `task_attempts_check1`: `CHECK (((finished_at IS NULL) OR (finished_at >= COALESCE(started_at, queued_at))))`.
- `task_attempts_check2`: `CHECK (((status = ANY (ARRAY['succeeded'::text, 'failed'::text, 'cancelled'::text])) = (finished_at IS NOT NULL)))`.
- `task_attempts_check3`: `CHECK (((status <> ALL (ARRAY['running'::text, 'succeeded'::text])) OR (started_at IS NOT NULL)))`.
- `task_attempts_check4`: `CHECK (((status <> 'failed'::text) OR (error_code IS NOT NULL)))`.
- `task_attempts_decision_id_fkey`: `FOREIGN KEY (decision_id) REFERENCES app.selection_decisions(id)`.
- `task_attempts_decision_id_key`: `UNIQUE (decision_id)`.
- `task_attempts_dispatch_reference_key`: `UNIQUE (dispatch_reference)`.
- `task_attempts_pkey`: `PRIMARY KEY (id)`.
- `task_attempts_status_check`: `CHECK ((status = ANY (ARRAY['queued'::text, 'running'::text, 'succeeded'::text, 'failed'::text, 'cancelled'::text])))`.

## task_measurements

Terminal telemetry snapshot; unknown utilization is not zero.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| attempt_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| processing_ms | bigint | YES | — | Processing-only elapsed time, milliseconds; distinct from whole-run time. |
| modeled_cost | numeric(20,10) | YES | — | Finite, nonnegative modeled amount in the referenced cost model; not an invoice. |
| cost_model_id | uuid | YES | — | Relational identifier; target and scope are specified by the foreign keys below. |
| actual_cpu_seconds | numeric(20,6) | YES | — | Observed CPU usage in seconds; NULL when unavailable, not allocated vCPU. |
| peak_memory_bytes | bigint | YES | — | Observed peak memory usage, bytes; NULL when unavailable. |
| unavailable_reason | text | YES | — | Required when the table-defined telemetry set is incomplete. |
| recorded_at | timestamp with time zone | NO | clock_timestamp() | Telemetry snapshot recording instant. |

Constraints:

- `task_measurements_actual_cpu_seconds_check`: `CHECK (((actual_cpu_seconds >= (0)::numeric) AND (actual_cpu_seconds < 'Infinity'::numeric)))`.
- `task_measurements_attempt_id_fkey`: `FOREIGN KEY (attempt_id) REFERENCES app.task_attempts(id)`.
- `task_measurements_check`: `CHECK (((modeled_cost IS NULL) OR (cost_model_id IS NOT NULL)))`.
- `task_measurements_check1`: `CHECK ((((processing_ms IS NOT NULL) AND (modeled_cost IS NOT NULL) AND (actual_cpu_seconds IS NOT NULL) AND (peak_memory_bytes IS NOT NULL)) OR ((unavailable_reason IS NOT NULL) AND (length(btrim(unavailable_reason)) > 0))))`.
- `task_measurements_cost_model_id_fkey`: `FOREIGN KEY (cost_model_id) REFERENCES app.cost_model_versions(id)`.
- `task_measurements_modeled_cost_check`: `CHECK (((modeled_cost >= (0)::numeric) AND (modeled_cost < 'Infinity'::numeric)))`.
- `task_measurements_peak_memory_bytes_check`: `CHECK ((peak_memory_bytes >= 0))`.
- `task_measurements_pkey`: `PRIMARY KEY (attempt_id)`.
- `task_measurements_processing_ms_check`: `CHECK ((processing_ms >= 0))`.

## user_credentials

Optional private 1:1 authentication record; no plaintext password is stored.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| user_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| password_hash | text | NO | — | PBKDF2-HMAC-SHA256, 600000 iterations, 16-byte salt and 32-byte digest, base64-encoded in the documented format. |
| updated_at | timestamp with time zone | NO | clock_timestamp() | Credential rotation timestamp. |

Constraints:

- `user_credentials_password_hash_check`: `CHECK ((password_hash ~ '^\$pbkdf2-sha256\$600000\$[A-Za-z0-9+/]{22}==\$[A-Za-z0-9+/]{43}=$'::text))`.
- `user_credentials_pkey`: `PRIMARY KEY (user_id)`.
- `user_credentials_user_id_fkey`: `FOREIGN KEY (user_id) REFERENCES app.users(id)`.

## users

Provisioned personal account and minimal contact data.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| id | uuid | NO | gen_random_uuid() | Stable generated UUID; never reused. |
| email | text | NO | — | Lowercase unique contact address; protected from service reader/writer roles. |
| display_name | text | NO | — | Private human-readable account name. |
| is_active | boolean | NO | true | Whether new launches are allowed for this account. |
| created_at | timestamp with time zone | NO | clock_timestamp() | Record creation time; timestamptz is an instant, display timezone is a client setting. |

Constraints:

- `users_display_name_check`: `CHECK (((length(btrim(display_name)) >= 1) AND (length(btrim(display_name)) <= 100)))`.
- `users_email_check`: `CHECK (((email = lower(email)) AND (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'::text)))`.
- `users_email_key`: `UNIQUE (email)`.
- `users_pkey`: `PRIMARY KEY (id)`.

## workflow_edges

Directed edge between nodes in one graph version.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| version_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| source_node_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| target_node_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |

Constraints:

- `workflow_edges_check`: `CHECK ((source_node_id <> target_node_id))`.
- `workflow_edges_pkey`: `PRIMARY KEY (version_id, source_node_id, target_node_id)`.
- `workflow_edges_version_id_fkey`: `FOREIGN KEY (version_id) REFERENCES app.workflow_versions(id)`.
- `workflow_edges_version_id_source_node_id_fkey`: `FOREIGN KEY (version_id, source_node_id) REFERENCES app.workflow_nodes(version_id, id)`.
- `workflow_edges_version_id_target_node_id_fkey`: `FOREIGN KEY (version_id, target_node_id) REFERENCES app.workflow_nodes(version_id, id)`.

## workflow_nodes

Version-scoped operation instance with small typed-contract parameters.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| id | uuid | NO | gen_random_uuid() | Stable generated UUID; never reused. |
| version_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| node_key | text | NO | — | Editor-stable node label unique within a version. |
| operation_version_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| parameters | jsonb | NO | '{}'::jsonb | Small object under the operation-version contract; no entity references or secrets embedded. |
| position_x | numeric(10,2) | NO | 0 | Editor canvas X coordinate. |
| position_y | numeric(10,2) | NO | 0 | Editor canvas Y coordinate. |

Constraints:

- `workflow_nodes_node_key_check`: `CHECK (((length(btrim(node_key)) >= 1) AND (length(btrim(node_key)) <= 80)))`.
- `workflow_nodes_operation_version_id_fkey`: `FOREIGN KEY (operation_version_id) REFERENCES app.operation_versions(id)`.
- `workflow_nodes_parameters_check`: `CHECK ((jsonb_typeof(parameters) = 'object'::text))`.
- `workflow_nodes_pkey`: `PRIMARY KEY (id)`.
- `workflow_nodes_version_id_fkey`: `FOREIGN KEY (version_id) REFERENCES app.workflow_versions(id)`.
- `workflow_nodes_version_id_id_key`: `UNIQUE (version_id, id)`.
- `workflow_nodes_version_id_node_key_key`: `UNIQUE (version_id, node_key)`.

## workflow_runs

Accepted launch referencing exact graph/input/policy and optional research trial.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| id | uuid | NO | gen_random_uuid() | Stable generated UUID; never reused. |
| version_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| input_artifact_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| policy_version_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| priority | text | NO | — | Normal workflow-level balanced, fastest or cheapest priority. |
| condition_id | uuid | YES | — | Relational identifier; target and scope are specified by the foreign keys below. |
| trial_no | integer | YES | — | Positive repetition number unique within condition; NULL outside research. |
| data_origin | text | NO | — | synthetic for invented fixtures; observed only for actually collected data. |
| request_key | uuid | NO | — | Idempotency UUID scoped to a saved version; matching repeats return the original run. |
| status | text | NO | 'accepted'::text | Lifecycle value constrained by table-specific CHECK and transition triggers. |
| accepted_at | timestamp with time zone | NO | clock_timestamp() | Backend launch acceptance boundary; excludes upload. |
| started_at | timestamp with time zone | YES | — | Observed start instant; immutable once filled. |
| finished_at | timestamp with time zone | YES | — | Observed terminal instant; not earlier than start/acceptance. |
| error_code | text | YES | — | Safe failure category; required for failed run/attempt. |

Constraints:

- `workflow_runs_check`: `CHECK (((condition_id IS NULL) = (trial_no IS NULL)))`.
- `workflow_runs_check1`: `CHECK (((started_at IS NULL) OR (started_at >= accepted_at)))`.
- `workflow_runs_check2`: `CHECK (((finished_at IS NULL) OR (finished_at >= COALESCE(started_at, accepted_at))))`.
- `workflow_runs_check3`: `CHECK (((status = ANY (ARRAY['succeeded'::text, 'failed'::text, 'cancelled'::text])) = (finished_at IS NOT NULL)))`.
- `workflow_runs_check4`: `CHECK (((status <> ALL (ARRAY['running'::text, 'succeeded'::text])) OR (started_at IS NOT NULL)))`.
- `workflow_runs_check5`: `CHECK (((status <> 'failed'::text) OR (error_code IS NOT NULL)))`.
- `workflow_runs_condition_id_fkey`: `FOREIGN KEY (condition_id) REFERENCES app.experiment_conditions(id)`.
- `workflow_runs_condition_id_trial_no_key`: `UNIQUE (condition_id, trial_no)`.
- `workflow_runs_data_origin_check`: `CHECK ((data_origin = ANY (ARRAY['synthetic'::text, 'observed'::text])))`.
- `workflow_runs_input_artifact_id_fkey`: `FOREIGN KEY (input_artifact_id) REFERENCES app.artifacts(id)`.
- `workflow_runs_pkey`: `PRIMARY KEY (id)`.
- `workflow_runs_policy_version_id_fkey`: `FOREIGN KEY (policy_version_id) REFERENCES app.selection_policy_versions(id)`.
- `workflow_runs_priority_check`: `CHECK ((priority = ANY (ARRAY['balanced'::text, 'fastest'::text, 'cheapest'::text])))`.
- `workflow_runs_status_check`: `CHECK ((status = ANY (ARRAY['accepted'::text, 'running'::text, 'succeeded'::text, 'failed'::text, 'cancelled'::text])))`.
- `workflow_runs_trial_no_check`: `CHECK ((trial_no > 0))`.
- `workflow_runs_version_id_fkey`: `FOREIGN KEY (version_id) REFERENCES app.workflow_versions(id)`.
- `workflow_runs_version_id_request_key_key`: `UNIQUE (version_id, request_key)`.

## workflow_versions

Saved graph snapshot; publication validates and freezes it.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| id | uuid | NO | gen_random_uuid() | Stable generated UUID; never reused. |
| workflow_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| version_no | integer | NO | — | Positive version number within its parent/code/environment. |
| created_at | timestamp with time zone | NO | clock_timestamp() | Record creation time; timestamptz is an instant, display timezone is a client setting. |
| published_at | timestamp with time zone | YES | — | NULL for draft; non-NULL freezes the complete graph. |

Constraints:

- `workflow_versions_check`: `CHECK (((published_at IS NULL) OR (published_at >= created_at)))`.
- `workflow_versions_pkey`: `PRIMARY KEY (id)`.
- `workflow_versions_version_no_check`: `CHECK ((version_no > 0))`.
- `workflow_versions_workflow_id_fkey`: `FOREIGN KEY (workflow_id) REFERENCES app.workflows(id)`.
- `workflow_versions_workflow_id_version_no_key`: `UNIQUE (workflow_id, version_no)`.

## workflows

Reusable named process and its owner; archive without losing history.

| Column | Type | NULL | Default | Meaning / quality |
| --- | --- | --- | --- | --- |
| id | uuid | NO | gen_random_uuid() | Stable generated UUID; never reused. |
| owner_id | uuid | NO | — | Relational identifier; target and scope are specified by the foreign keys below. |
| name | text | NO | — | Human-readable workflow name. |
| archived_at | timestamp with time zone | YES | — | NULL while active; archival blocks new launches. |
| created_at | timestamp with time zone | NO | clock_timestamp() | Record creation time; timestamptz is an instant, display timezone is a client setting. |

Constraints:

- `workflows_check`: `CHECK (((archived_at IS NULL) OR (archived_at >= created_at)))`.
- `workflows_name_check`: `CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 120)))`.
- `workflows_owner_id_fkey`: `FOREIGN KEY (owner_id) REFERENCES app.users(id)`.
- `workflows_pkey`: `PRIMARY KEY (id)`.

## Indexes

Unique and primary-key indexes are listed alongside explicit query/FK indexes. See design.md for query rationale.

- `artifact_expiry`: `CREATE INDEX artifact_expiry ON app.artifacts USING btree (expires_at) WHERE ((state = 'complete'::text) AND (expires_at IS NOT NULL))`.
- `artifact_owner_created`: `CREATE INDEX artifact_owner_created ON app.artifacts USING btree (owner_id, created_at DESC)`.
- `artifacts_pkey`: `CREATE UNIQUE INDEX artifacts_pkey ON app.artifacts USING btree (id)`.
- `artifacts_storage_key_key`: `CREATE UNIQUE INDEX artifacts_storage_key_key ON app.artifacts USING btree (storage_key)`.
- `candidate_evidence_links_pkey`: `CREATE UNIQUE INDEX candidate_evidence_links_pkey ON app.candidate_evidence_links USING btree (candidate_id, calibration_run_id)`.
- `evidence_calibration`: `CREATE INDEX evidence_calibration ON app.candidate_evidence_links USING btree (calibration_run_id)`.
- `cost_model_versions_code_version_no_key`: `CREATE UNIQUE INDEX cost_model_versions_code_version_no_key ON app.cost_model_versions USING btree (code, version_no)`.
- `cost_model_versions_pkey`: `CREATE UNIQUE INDEX cost_model_versions_pkey ON app.cost_model_versions USING btree (id)`.
- `candidate_cost_model`: `CREATE INDEX candidate_cost_model ON app.decision_candidates USING btree (cost_model_id)`.
- `candidate_runtime`: `CREATE INDEX candidate_runtime ON app.decision_candidates USING btree (runtime_configuration_id)`.
- `decision_candidates_decision_id_id_key`: `CREATE UNIQUE INDEX decision_candidates_decision_id_id_key ON app.decision_candidates USING btree (decision_id, id)`.
- `decision_candidates_decision_id_runtime_configuration_id_key`: `CREATE UNIQUE INDEX decision_candidates_decision_id_runtime_configuration_id_key ON app.decision_candidates USING btree (decision_id, runtime_configuration_id)`.
- `decision_candidates_pkey`: `CREATE UNIQUE INDEX decision_candidates_pkey ON app.decision_candidates USING btree (id)`.
- `experiment_conditions_pkey`: `CREATE UNIQUE INDEX experiment_conditions_pkey ON app.experiment_conditions USING btree (id)`.
- `experiment_conditions_scenario_input_volume_arrival_pattern_key`: `CREATE UNIQUE INDEX experiment_conditions_scenario_input_volume_arrival_pattern_key ON app.experiment_conditions USING btree (scenario, input_volume, arrival_pattern, mode, dataset_split, fixture_key, protocol_version)`.
- `execution_node`: `CREATE INDEX execution_node ON app.node_executions USING btree (node_id)`.
- `node_executions_pkey`: `CREATE UNIQUE INDEX node_executions_pkey ON app.node_executions USING btree (id)`.
- `node_executions_run_id_node_id_key`: `CREATE UNIQUE INDEX node_executions_run_id_node_id_key ON app.node_executions USING btree (run_id, node_id)`.
- `operation_versions_code_version_key`: `CREATE UNIQUE INDEX operation_versions_code_version_key ON app.operation_versions USING btree (code, version)`.
- `operation_versions_pkey`: `CREATE UNIQUE INDEX operation_versions_pkey ON app.operation_versions USING btree (id)`.
- `run_measurements_pkey`: `CREATE UNIQUE INDEX run_measurements_pkey ON app.run_measurements USING btree (run_id)`.
- `result_attempt`: `CREATE INDEX result_attempt ON app.run_results USING btree (source_attempt_id)`.
- `result_file`: `CREATE INDEX result_file ON app.run_results USING btree (artifact_id)`.
- `run_results_pkey`: `CREATE UNIQUE INDEX run_results_pkey ON app.run_results USING btree (run_id, artifact_id)`.
- `run_verifications_pkey`: `CREATE UNIQUE INDEX run_verifications_pkey ON app.run_verifications USING btree (run_id)`.
- `runtime_configurations_environment_version_no_key`: `CREATE UNIQUE INDEX runtime_configurations_environment_version_no_key ON app.runtime_configurations USING btree (environment, version_no)`.
- `runtime_configurations_pkey`: `CREATE UNIQUE INDEX runtime_configurations_pkey ON app.runtime_configurations USING btree (id)`.
- `schema_migrations_pkey`: `CREATE UNIQUE INDEX schema_migrations_pkey ON app.schema_migrations USING btree (version)`.
- `selection_decisions_execution_id_attempt_no_key`: `CREATE UNIQUE INDEX selection_decisions_execution_id_attempt_no_key ON app.selection_decisions USING btree (execution_id, attempt_no)`.
- `selection_decisions_pkey`: `CREATE UNIQUE INDEX selection_decisions_pkey ON app.selection_decisions USING btree (id)`.
- `selection_policy_versions_code_version_no_key`: `CREATE UNIQUE INDEX selection_policy_versions_code_version_no_key ON app.selection_policy_versions USING btree (code, version_no)`.
- `selection_policy_versions_pkey`: `CREATE UNIQUE INDEX selection_policy_versions_pkey ON app.selection_policy_versions USING btree (id)`.
- `task_artifact_file`: `CREATE INDEX task_artifact_file ON app.task_artifacts USING btree (artifact_id)`.
- `task_artifacts_pkey`: `CREATE UNIQUE INDEX task_artifacts_pkey ON app.task_artifacts USING btree (attempt_id, direction, port_name)`.
- `task_attempts_decision_id_key`: `CREATE UNIQUE INDEX task_attempts_decision_id_key ON app.task_attempts USING btree (decision_id)`.
- `task_attempts_dispatch_reference_key`: `CREATE UNIQUE INDEX task_attempts_dispatch_reference_key ON app.task_attempts USING btree (dispatch_reference)`.
- `task_attempts_pkey`: `CREATE UNIQUE INDEX task_attempts_pkey ON app.task_attempts USING btree (id)`.
- `task_measurements_pkey`: `CREATE UNIQUE INDEX task_measurements_pkey ON app.task_measurements USING btree (attempt_id)`.
- `user_credentials_pkey`: `CREATE UNIQUE INDEX user_credentials_pkey ON app.user_credentials USING btree (user_id)`.
- `users_email_key`: `CREATE UNIQUE INDEX users_email_key ON app.users USING btree (email)`.
- `users_pkey`: `CREATE UNIQUE INDEX users_pkey ON app.users USING btree (id)`.
- `edge_target`: `CREATE INDEX edge_target ON app.workflow_edges USING btree (version_id, target_node_id)`.
- `workflow_edges_pkey`: `CREATE UNIQUE INDEX workflow_edges_pkey ON app.workflow_edges USING btree (version_id, source_node_id, target_node_id)`.
- `node_operation`: `CREATE INDEX node_operation ON app.workflow_nodes USING btree (operation_version_id)`.
- `workflow_nodes_pkey`: `CREATE UNIQUE INDEX workflow_nodes_pkey ON app.workflow_nodes USING btree (id)`.
- `workflow_nodes_version_id_id_key`: `CREATE UNIQUE INDEX workflow_nodes_version_id_id_key ON app.workflow_nodes USING btree (version_id, id)`.
- `workflow_nodes_version_id_node_key_key`: `CREATE UNIQUE INDEX workflow_nodes_version_id_node_key_key ON app.workflow_nodes USING btree (version_id, node_key)`.
- `run_active`: `CREATE INDEX run_active ON app.workflow_runs USING btree (accepted_at) WHERE (status = ANY (ARRAY['accepted'::text, 'running'::text]))`.
- `run_input`: `CREATE INDEX run_input ON app.workflow_runs USING btree (input_artifact_id)`.
- `run_policy`: `CREATE INDEX run_policy ON app.workflow_runs USING btree (policy_version_id)`.
- `run_version_accepted`: `CREATE INDEX run_version_accepted ON app.workflow_runs USING btree (version_id, accepted_at DESC)`.
- `workflow_runs_condition_id_trial_no_key`: `CREATE UNIQUE INDEX workflow_runs_condition_id_trial_no_key ON app.workflow_runs USING btree (condition_id, trial_no)`.
- `workflow_runs_pkey`: `CREATE UNIQUE INDEX workflow_runs_pkey ON app.workflow_runs USING btree (id)`.
- `workflow_runs_version_id_request_key_key`: `CREATE UNIQUE INDEX workflow_runs_version_id_request_key_key ON app.workflow_runs USING btree (version_id, request_key)`.
- `workflow_versions_pkey`: `CREATE UNIQUE INDEX workflow_versions_pkey ON app.workflow_versions USING btree (id)`.
- `workflow_versions_workflow_id_version_no_key`: `CREATE UNIQUE INDEX workflow_versions_workflow_id_version_no_key ON app.workflow_versions USING btree (workflow_id, version_no)`.
- `workflow_owner_created`: `CREATE INDEX workflow_owner_created ON app.workflows USING btree (owner_id, created_at DESC)`.
- `workflows_pkey`: `CREATE UNIQUE INDEX workflows_pkey ON app.workflows USING btree (id)`.
