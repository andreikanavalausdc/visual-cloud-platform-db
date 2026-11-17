# Database design

PostgreSQL OLTP stores the reusable workflow definitions and the evidence needed to explain their execution. File contents belong in an external artifact store; the database holds owned metadata and locators. The API, frontend, AWS processors and actual storage integration remain future work. Supplied runs and measurements are synthetic fixtures.

## Domain model

| Relation | Purpose |
| --- | --- |
| users → workflows | Personal ownership of reusable processes |
| workflows → workflow_versions | Immutable saved definitions; edits create new versions |
| workflow_versions → workflow_nodes / workflow_edges | Version-scoped executable graph |
| operation_versions | Frozen operation contracts and parameter shapes |
| workflow_runs → node_executions | One launch on a particular input and one logical execution per node |
| node_executions → selection_decisions → task_attempts | A recorded choice before each independent dispatch attempt |
| decision_candidates / candidate_evidence_links | Eligibility, exclusions, forecasts and earlier calibration evidence |
| artifacts / task_artifacts / run_results | Owned input/output references and their producing attempts |
| experiment_conditions | Scenario, volume, arrival pattern, mode, dataset split and protocol |
| task_measurements / run_measurements / run_verifications | Telemetry and correctness evidence, kept separately |

Tables are created with plural names directly in the initial schema; foreign-key identifiers stay singular. The business decomposition targets 3NF. Contact data belongs to users, operation semantics to operation_versions, environment allocation to runtime_configurations, and rates/currency to cost_model_versions. JSONB is limited to small versioned parameter/configuration objects; it does not replace entity relationships.

workflow_edges.version_id is a documented physical redundancy: two composite foreign keys enforce that both endpoints belong to one version. Supporting unique keys provide the referenced scope.

## Integrity and transactions

- Publication checks 1–30 nodes, supported CSV parameter contracts, compatible edge types, absence of cycles and one sequential path. Published versions and their graph records become immutable.
- Graph edits lock the parent version. Publication cannot silently interleave with a child change.
- create_run atomically creates the launch and all node executions. A transaction-scoped advisory lock serializes the same version/request key; identical repeats return the existing run and changed payloads are rejected.
- Launch inputs must be complete, available, compatible and owned by the workflow owner. Cross-owner task artifact relationships are rejected.
- A decision is sealed before an attempt can be created. Its chosen candidate must belong to it and be eligible. An all-ineligible decision retains its reasons and cannot dispatch.
- Candidate and evidence edits lock the parent decision. A sealed snapshot is immutable. Calibration links require an earlier successful run for the environment, operation and data origin; evaluation data cannot serve as calibration evidence.
- A logical node can have distinct failed/retried attempts, but not another active or successful attempt in parallel. Terminal attempts and runs cannot be rewritten.
- Results must come from successful attempts of the same run. Successful run completion requires successful nodes and at least one linked result.

PostgreSQL records durable dispatch intent but does not implement distributed exactly-once execution. The future dispatcher/orchestrator must reconcile ambiguous external submissions, enforce dependency readiness and apply bounded retry/cancellation policies.

## Measurements and files

Runtime success is distinct from correctness. Research statistics require both success and a passed correctness record; views retain counts of failures, unfinished/unverified cases and missing values. Groups separate protocol, fixture, split, mode, origin and cost model/currency. The seed has one calibration trial and six evaluation conditions with two repetitions, not the final 48-condition research study.

Money uses finite nonnegative numeric values under an immutable model. Modeled cost is not an invoice. Worker idle allocation identifies its observation period. Actual CPU/RAM utilization is distinct from configured resources. Unknown telemetry stays NULL with an explanation.

Artifacts enforce the 10 MiB and 20-million-decoded-pixel limits and complete-file checksums. An expiry deadline changes availability without erasing history. Actual upload/download authorization, the BA-defined 30-day retention assignment and physical object cleanup are future integration work.

## Docker startup and access

The PostgreSQL 17 image is extended with Python for the verification suite. Docker Compose reads POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD, APP_DB_USER, APP_DB_PASSWORD and DB_PORT from the local .env file. Only the placeholder .env.example is committed; .env is ignored by Git and excluded from the image build context. The official PostgreSQL entrypoint initializes the dedicated database, then runs db/install.sql and provisions the non-superuser APP_DB_USER login. A completion marker and healthcheck prevent an incomplete database from being reported ready.

The named volume stores database files, including PostgreSQL password verifiers. Connection credentials are configured in .env. Normal container recreation, stop and docker compose down preserve it. Initial seed/migrations run once for an empty volume; restarting does not reset data or duplicate seed records. Future schema changes require reviewed forward migrations, not edits to applied history or automatic data deletion. docker compose down -v explicitly deletes the stored database. Initialization variables apply when creating a new volume; editing a password in .env alone does not rotate an existing PostgreSQL role password. Existing role passwords must be changed in PostgreSQL as well.

The published port defaults to 127.0.0.1:5433, avoiding a typical native PostgreSQL port. DB_PORT may override it through Compose's normal environment configuration if needed.

| Role | Access |
| --- | --- |
| vcp_admin | NOLOGIN schema owner for controlled migrations/provisioning |
| vcp_write | Explicit domain DML and launch helper; no schema management or credential/contact reads |
| vcp_read | Four approved reporting views |
| APP_DB_USER (vcp_service by default) | Automatically provisioned non-superuser login, member of vcp_write only |

New objects fail closed until a migration explicitly grants access. PUBLIC function execution is revoked from the owner's defaults. End-user authentication and per-user API authorization are not implemented by the shared service login; database cross-owner relationship checks are not RLS.

v_users_masked redacts contacts/names and uses a UUID label; it is masking/pseudonymization, not irreversible anonymization. account credential records use PBKDF2-HMAC-SHA256 with 600000 iterations, a random 16-byte salt and 32-byte digest. The seed source password was discarded and provides no usable personal login. Real authentication, work-factor benchmarking and credential rotation remain integration work.

## Indexes and evidence

PK/UNIQUE constraints supply their own indexes. The 16 additional indexes support owner-scoped lists, latest runs, reverse edges, reference lookups, active-run reconciliation and available-artifact expiry. The recorded plan may prefer a sequential scan for the tiny seed; no throughput or API-latency improvement is claimed.

[verification-report.json](verification-report.json) records the runtime, actual PostgreSQL version, 69 checks and SQL hashes. [query-plan.json](query-plan.json) is an actual EXPLAIN ANALYZE result. Docker initialization/login/persistence checks are exercised in addition to the existing SQL/concurrency suite. [data-dictionary.md](data-dictionary.md) lists the exact installed columns and constraints; [schema-overview.svg](schema-overview.svg) and [logical-schema.mmd](logical-schema.mmd) show the model.
