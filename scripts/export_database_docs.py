import argparse
import json
import re
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--psql',default='psql')
a=p.parse_args()

def query(s):
    r=subprocess.run([a.psql,'-X','-q','-t','-A','-v','ON_ERROR_STOP=1'],input=s,text=True,
                     capture_output=True,encoding='utf-8',timeout=20)
    if r.returncode: raise RuntimeError(r.stderr)
    return json.loads(r.stdout)

tables=query("""SELECT json_agg(x ORDER BY table_name) FROM (
 SELECT t.table_name,obj_description(c.oid) AS comment,
   (SELECT count(*) FROM information_schema.columns z WHERE z.table_schema='app' AND z.table_name=t.table_name) AS column_count
 FROM information_schema.tables t JOIN pg_class c ON c.relname=t.table_name JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE t.table_schema='app' AND t.table_type='BASE TABLE' AND n.nspname='app') x;""")
cols=query("""SELECT json_agg(x ORDER BY table_name,ordinal_position) FROM (
 SELECT c.table_name,c.column_name,c.ordinal_position,c.data_type,c.udt_name,c.is_nullable,c.column_default,
   c.numeric_precision,c.numeric_scale,col_description(pc.oid,c.ordinal_position) AS comment
 FROM information_schema.columns c JOIN pg_class pc ON pc.relname=c.table_name JOIN pg_namespace n ON n.oid=pc.relnamespace
 WHERE c.table_schema='app' AND n.nspname='app' AND pc.relkind='r') x;""")
constraints=query("""SELECT json_agg(x ORDER BY table_name,name) FROM (
 SELECT c.relname AS table_name,co.conname AS name,co.contype AS type,pg_get_constraintdef(co.oid) AS definition,
   rc.relname AS referenced_table
 FROM pg_constraint co JOIN pg_class c ON c.oid=co.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace
 LEFT JOIN pg_class rc ON rc.oid=co.confrelid WHERE n.nspname='app') x;""")
indexes=query("SELECT json_agg(x ORDER BY tablename,indexname) FROM (SELECT tablename,indexname,indexdef FROM pg_indexes WHERE schemaname='app') x;")
purposes={
 'schema_migrations':'Applied schema versions; source history is kept in Git.',
 'users':'Provisioned personal account and minimal contact data.',
 'user_credentials':'Optional private 1:1 authentication record; no plaintext password is stored.',
 'operation_versions':'Immutable operation contract and typed input/output formats.',
 'workflows':'Reusable named process and its owner; archive without losing history.',
 'workflow_versions':'Saved graph snapshot; publication validates and freezes it.',
 'workflow_nodes':'Version-scoped operation instance with small typed-contract parameters.',
 'workflow_edges':'Directed edge between nodes in one graph version.',
 'artifacts':'Owned file metadata and private external storage locator; no file body.',
 'runtime_configurations':'Immutable environment/resource configuration; not actual utilization.',
 'selection_policy_versions':'Immutable selection policy description; no implemented selector is implied.',
 'cost_model_versions':'Immutable currency, rate date and declared accounting scope.',
 'experiment_conditions':'One frozen research condition; repetitions are separate runs.',
 'workflow_runs':'Accepted launch referencing exact graph/input/policy and optional research trial.',
 'node_executions':'One logical execution of a saved node in a run.',
 'selection_decisions':'Pre-dispatch choice or no-eligible record; seal before dispatch.',
 'decision_candidates':'Eligibility, exclusions, forecasts and immutable runtime candidate identity.',
 'candidate_evidence_links':'Many-to-many links from candidates to earlier successful calibration runs.',
 'task_attempts':'One dispatch attempt under one sealed decision; retries stay separate.',
 'task_artifacts':'Input/output port binding for an attempt; cannot bind a foreign owner.',
 'run_results':'Final output bound to a successful attempt in the same run.',
 'task_measurements':'Terminal telemetry snapshot; unknown utilization is not zero.',
 'run_measurements':'End-to-end time and nominal modeled cost with optional worker idle allocation.',
 'run_verifications':'Explicit correctness evidence independent of runtime success.'}
meaning={
 'id':'Stable generated UUID; never reused.', 'email':'Lowercase unique contact address; protected from service reader/writer roles.',
 'display_name':'Private human-readable account name.', 'is_active':'Whether new launches are allowed for this account.',
 'password_hash':'PBKDF2-HMAC-SHA256, 600000 iterations, 16-byte salt and 32-byte digest, base64-encoded in the documented format.',
 'created_at':'Record creation time; timestamptz is an instant, display timezone is a client setting.',
 'updated_at':'Credential rotation timestamp.', 'archived_at':'NULL while active; archival blocks new launches.',
 'version':'Applied schema version or immutable operation version number, according to table.',
 'version_no':'Positive version number within its parent/code/environment.', 'description':'Human-readable purpose; no secrets.',
 'applied_at':'Migration application instant.', 'code':'Stable semantic identifier, not a display label.',
 'input_kind':'Declared input format.', 'output_kind':'Declared output format.',
 'parameter_contract':'Documented operation-specific JSON contract; validated CSV subset is implemented in valid_parameters.',
 'name':'Human-readable workflow name.', 'published_at':'NULL for draft; non-NULL freezes the complete graph.',
 'node_key':'Editor-stable node label unique within a version.', 'parameters':'Small object under the operation-version contract; no entity references or secrets embedded.',
 'position_x':'Editor canvas X coordinate.', 'position_y':'Editor canvas Y coordinate.',
 'storage_key':'Private opaque file locator; never a secret or signed download URL.', 'original_name':'Safe metadata filename; application still sanitizes it for downloads.',
 'media_kind':'CSV/JSON/image classification.', 'size_bytes':'Stored file byte size, 0..10485760.',
 'decoded_pixels':'Decoded image pixel count, 1..20000000; NULL for non-images.',
 'sha256':'Lowercase content checksum, never a password hashing method.',
 'state':'File lifecycle: pending, complete, expired, deleted.', 'expires_at':'Optional availability deadline; background physical deletion is future work.',
 'environment':'worker, lambda or fargate.', 'region':'Configured region; synthetic-region in fixtures is not deployed.',
 'execution_model':'Named invocation/container/process model.', 'cpu_units':'Configured CPU allocation, not observed usage.',
 'memory_mib':'Configured RAM allocation, not observed usage.', 'settings':'Small non-secret environment settings object.',
 'definition':'Frozen policy description; algorithm calibration remains future work.',
 'currency':'Three-letter uppercase currency identifier.', 'rate_date':'Date to which the versioned rates apply.',
 'accounting_scope':'Included/excluded modeled cost items; hosting and invoices are separate.', 'rates':'Structured versioned rates; demo values are synthetic.',
 'scenario':'CSV or image research workload.', 'input_volume':'Named small/large size band; exact fixture defines its bytes.',
 'arrival_pattern':'Isolated or grouped arrival protocol.', 'mode':'Three fixed research baselines or three automatic priorities.',
 'dataset_split':'Calibration or held-out evaluation. Evaluation cannot be cited as calibration evidence.',
 'fixture_key':'Versioned dataset reference, not file bytes.', 'protocol_version':'Frozen experiment protocol identifier.',
 'priority':'Normal workflow-level balanced, fastest or cheapest priority.', 'trial_no':'Positive repetition number unique within condition; NULL outside research.',
 'data_origin':'synthetic for invented fixtures; observed only for actually collected data.',
 'request_key':'Idempotency UUID scoped to a saved version; matching repeats return the original run.',
 'status':'Lifecycle value constrained by table-specific CHECK and transition triggers.',
 'accepted_at':'Backend launch acceptance boundary; excludes upload.', 'queued_at':'Durable attempt creation before external dispatch.',
 'started_at':'Observed start instant; immutable once filled.', 'finished_at':'Observed terminal instant; not earlier than start/acceptance.',
 'error_code':'Safe failure category; required for failed run/attempt.', 'safe_error_message':'Sanitized diagnostic text; no raw payload or credentials.',
 'attempt_no':'Positive retry index for a logical node execution.', 'is_fallback':'Whether the selected eligible candidate is a fallback.',
 'explanation':'Readable selection or rejection explanation.', 'sealed_at':'Seal instant; freezes decision, candidates and evidence links.',
 'eligible':'Technical eligibility flag; false requires an exclusion reason.', 'exclusion_reason':'Nonblank reason for an ineligible candidate; NULL for eligible.',
 'predicted_ms':'Pre-run duration forecast in milliseconds; NULL if not available.',
 'predicted_cost':'Pre-run nominal forecast in the referenced cost model currency.',
 'uncertainty_note':'Qualitative uncertainty, without an invented numeric error bound.',
 'dispatch_reference':'Opaque external execution identity; synthetic:// in fixtures; no credentials.',
 'direction':'Input or output binding.', 'port_name':'Operation port name; one artifact per attempt/direction/port.',
 'processing_ms':'Processing-only elapsed time, milliseconds; distinct from whole-run time.',
 'modeled_cost':'Finite, nonnegative modeled amount in the referenced cost model; not an invoice.',
 'actual_cpu_seconds':'Observed CPU usage in seconds; NULL when unavailable, not allocated vCPU.',
 'peak_memory_bytes':'Observed peak memory usage, bytes; NULL when unavailable.',
 'unavailable_reason':'Required when the table-defined telemetry set is incomplete.', 'recorded_at':'Telemetry snapshot recording instant.',
 'end_to_end_ms':'Whole workflow time from accepted launch to ready result, in milliseconds.',
 'observation_window_start':'Start of explicit worker capacity/idle accounting period.',
 'observation_window_end':'End of that period; greater than its start.',
 'allocated_idle_cost':'Idle-capacity cost allocated to this run; same model/currency, explicit period required.',
 'outcome':'Correctness passed/failed, independently of execution status.', 'checker_version':'Versioned correctness checking method.',
 'expected_result_key':'Reference to known expected result/semantic properties.', 'checked_at':'Correctness check timestamp.',
 'note':'Evidence limitations and explanation; synthetic fixtures explicitly say no processor check was executed.'}

def esc(s): return str(s).replace('|','\\|').replace('\n',' ')

lines=['# PostgreSQL data dictionary','',
 'Generated from the installed `app` schema by `scripts/export_database_docs.py`. Business meanings are maintained in that script. SQL constraints below are the actual database definitions.','',
 'The database has 24 tables including migration history, 4 views, and typed relational links. All timestamps use `timestamptz`; no file body is stored here.','']
for t in tables:
    name=t['table_name']
    lines += ['## '+name,'',purposes[name],'']
    if t['comment']: lines += [t['comment'],'']
    lines += ['| Column | Type | NULL | Default | Meaning / quality |','| --- | --- | --- | --- | --- |']
    for c in [x for x in cols if x['table_name']==name]:
        typ=c['data_type']
        if typ=='numeric': typ=f"numeric({c['numeric_precision']},{c['numeric_scale']})"
        desc=c['comment'] or meaning.get(c['column_name'])
        if not desc and c['column_name'].endswith('_id'):
            desc='Relational identifier; target and scope are specified by the foreign keys below.'
        if not desc: raise ValueError('Missing dictionary meaning: '+name+'.'+c['column_name'])
        lines.append('| '+' | '.join(esc(v) for v in [c['column_name'],typ,c['is_nullable'],c['column_default'] or '—',desc])+' |')
    lines += ['','Constraints:','']
    for co in [x for x in constraints if x['table_name']==name]:
        lines.append('- `'+co['name']+'`: `'+co['definition']+'`.')
    lines += ['']
lines += ['## Indexes','', 'Unique and primary-key indexes are listed alongside explicit query/FK indexes. See design.md for query rationale.','']
for i in indexes: lines.append('- `'+i['indexname']+'`: `'+i['indexdef']+'`.')
dest=ROOT/'docs/database';dest.mkdir(parents=True,exist_ok=True)
(dest/'data-dictionary.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
(dest/'schema-metadata.json').write_text(json.dumps({'tables':tables,'columns':cols,'constraints':constraints,'indexes':indexes},indent=2)+'\n',encoding='utf-8')

mermaid=['erDiagram']
for t in tables:
    mermaid.append('  '+t['table_name']+' {')
    for c in [x for x in cols if x['table_name']==t['table_name']]:
        mermaid.append('    '+c['udt_name'].replace(' ','_')+' '+c['column_name'])
    mermaid.append('  }')
for co in constraints:
    if co['type']=='f':
        fk_cols=set(re.search(r'FOREIGN KEY \(([^)]+)\)',co['definition'])[1].split(', '))
        child_keys=[set(re.search(r'\(([^)]+)\)',x['definition'])[1].split(', ')) for x in constraints
                    if x['table_name']==co['table_name'] and x['type'] in ('p','u')]
        unique=any(k<=fk_cols for k in child_keys)
        optional=any(c['is_nullable']=='YES' for c in cols if c['table_name']==co['table_name'] and c['column_name'] in fk_cols)
        left='|o' if optional else '||'
        right='o|' if unique else 'o{'
        mermaid.append('  '+co['referenced_table']+' '+left+'--'+right+' '+co['table_name']+' : "'+co['name']+'"')
(dest/'logical-schema.mmd').write_text('\n'.join(mermaid)+'\n',encoding='utf-8')
print(json.dumps({'tables':len(tables),'columns':len(cols),'foreign_keys':sum(x['type']=='f' for x in constraints),'indexes':len(indexes)}))
