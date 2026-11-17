import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
from datetime import datetime, timezone
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--psql', default='psql')
args = parser.parse_args()
base = [args.psql, '-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1']

def sql(statement, *, env=None):
    p = subprocess.run(base, input=statement, text=True, capture_output=True,
                       encoding='utf-8', env=env, timeout=20)
    if p.returncode:
        raise RuntimeError(p.stderr)
    return p.stdout.strip()

def run_file(name):
    p = subprocess.run(base + ['-f', str(ROOT/name)], text=True, capture_output=True,
                       encoding='utf-8', timeout=30)
    if p.returncode:
        raise RuntimeError(p.stderr)
    results = re.findall(r'NOTICE:\s+PASS: (.+)', p.stderr)
    if not results:
        raise RuntimeError('No assertions executed: '+name)
    return results

def wait_for_sleep(tag, process):
    deadline = time.monotonic()+5
    while time.monotonic()<deadline:
        if sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='"+tag+"' AND wait_event='PgSleep';") == '1':
            return
        if process.poll() is not None:
            raise RuntimeError('First session finished before concurrent session was ready')
        time.sleep(0.03)
    raise RuntimeError('Concurrent session did not reach the synchronized wait')

def spawn_waiting(statement, tag):
    env = dict(os.environ, PGAPPNAME=tag)
    p = subprocess.Popen(base, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, encoding='utf-8', env=env)
    p.stdin.write(statement)
    p.stdin.close()
    p.stdin = None
    return p

checks = run_file('db/checks/integrity.sql') + run_file('db/checks/permissions.sql')
fixture = json.loads(sql("""SELECT json_build_object(
  'version',(SELECT id FROM app.workflow_versions WHERE version_no=1),
  'input',(SELECT id FROM app.artifacts WHERE storage_key='synthetic://alice/input-a'),
  'policy',(SELECT id FROM app.selection_policy_versions WHERE code='demo-policy'),
  'node',(SELECT n.id FROM app.workflow_nodes n JOIN app.workflow_versions v ON v.id=n.version_id WHERE v.version_no=1 AND n.node_key='filter'));
"""))
request = str(uuid.uuid4())
call = "SELECT app.create_run('{version}','{input}','{policy}','balanced','"+request+"','synthetic');"
call = call.format(**fixture)
p = spawn_waiting('BEGIN; SET LOCAL ROLE vcp_write; '+call+' SELECT pg_sleep(1); COMMIT;', 'vcp_verify_idempotency')
wait_for_sleep('vcp_verify_idempotency',p)
t0 = time.monotonic()
second = sql('SET ROLE vcp_write; '+call)
blocked = time.monotonic()-t0
out,err = p.communicate(timeout=10)
first = re.findall(r'^[a-f0-9-]{36}$', out, re.M)
if p.returncode or len(first)!=1 or first[0]!=second or blocked<0.3:
    raise RuntimeError('Concurrent idempotency failed: '+err)
if sql("SELECT count(*) FROM app.node_executions WHERE run_id='"+second+"';")!='4':
    raise RuntimeError('Concurrent launch did not create exactly four executions')
checks.append('concurrent launch requests create one run and exactly four node executions')

sql("BEGIN; DELETE FROM app.node_executions WHERE run_id='"+second+"'; DELETE FROM app.workflow_runs WHERE id='"+second+"' AND request_key='"+request+"' AND data_origin='synthetic' AND status='accepted'; COMMIT;")

p = spawn_waiting("BEGIN; SELECT id FROM app.workflow_versions WHERE id='"+fixture['version']+"' FOR UPDATE; SELECT pg_sleep(1); COMMIT;", 'vcp_verify_graph_lock')
wait_for_sleep('vcp_verify_graph_lock',p)
t0 = time.monotonic()
mutation = subprocess.run(base, input="SET ROLE vcp_write; UPDATE app.workflow_nodes SET position_x=999 WHERE id='"+fixture['node']+"';",
                          text=True,capture_output=True,encoding='utf-8',timeout=10)
blocked_graph = time.monotonic()-t0
out,err = p.communicate(timeout=10)
if p.returncode or mutation.returncode==0 or 'Published graph is immutable' not in mutation.stderr or blocked_graph<0.3:
    raise RuntimeError('Concurrent graph lock/immutability check failed: '+err+mutation.stderr)
checks.append('graph edit waits for parent-version lock and cannot alter a published graph')

sql('ANALYZE app.workflows; ANALYZE app.workflow_runs;')
plan = json.loads(sql("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT * FROM app.workflow_runs WHERE version_id='"+fixture['version']+"' ORDER BY accepted_at DESC LIMIT 10;"))
report = {
    'verified_at_utc':datetime.now(timezone.utc).isoformat(),
    'runtime':os.environ.get('VCP_RUNTIME','native'),
    'postgres_version':sql('SHOW server_version;'),
    'database':sql('SELECT current_database();'),
    'status':'pass', 'assertion_count':len(checks), 'checks':checks,
    'concurrency_block_seconds':{'idempotent_launch':round(blocked,3),'graph_edit':round(blocked_graph,3)},
    'scope':'Database-layer synthetic fixtures only. No NestJS, React, AWS processors, market or benchmark evidence.',
    'sql_sha256':{str(p.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/'db').rglob('*.sql'))},
    'counts':json.loads(sql("SELECT json_build_object('tables',(SELECT count(*) FROM information_schema.tables WHERE table_schema='app' AND table_type='BASE TABLE'),'runs',(SELECT count(*) FROM app.workflow_runs),'attempts',(SELECT count(*) FROM app.task_attempts),'views',(SELECT count(*) FROM information_schema.views WHERE table_schema='app'));"))
}
dest=ROOT/'docs/database'
dest.mkdir(parents=True,exist_ok=True)
(dest/'verification-report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
(dest/'query-plan.json').write_text(json.dumps(plan,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'status':report['status'],'assertions':len(checks),'counts':report['counts']},ensure_ascii=False))
