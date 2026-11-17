from pathlib import Path
from html import escape

ROOT=Path(__file__).resolve().parents[1]
W,H=1950,980
cards=[
 (60,160,'01  OWNERSHIP', ['users','user_credentials  [optional 1:1]','workflows'], ['Account owns reusable processes.','Private credentials use a separate table.']),
 (530,160,'02  SAVED GRAPH', ['workflow_versions','workflow_nodes / workflow_edges','operation_versions'], ['One version contains nodes and edges.','Published graphs are immutable.']),
 (1000,160,'03  LAUNCH', ['workflow_runs','node_executions','run_results'], ['Run references one exact saved version.','Node execution is separate from retries.']),
 (1470,160,'04  ATTEMPT', ['task_attempts','task_artifacts','task_measurements'], ['Each attempt has a sealed decision.','Files and terminal telemetry are linked.']),
 (60,560,'05  FILE METADATA', ['artifacts'], ['Owned references, checksum, size, expiry.','File bodies stay outside PostgreSQL.','A missing file does not erase run history.']),
 (530,560,'06  FROZEN CONFIGURATION', ['runtime_configurations','selection_policy_versions','cost_model_versions'], ['Environment, policy and rates are versioned.','Configured resources differ from utilization.']),
 (1000,560,'07  AUDITABLE CHOICE', ['selection_decisions','decision_candidates','candidate_evidence_links'], ['Candidate eligibility, estimates, exclusions.','Only earlier calibration is usable evidence.']),
 (1470,560,'08  RESEARCH', ['experiment_conditions','run_measurements','run_verifications'], ['Condition, repetition and correctness differ.','Failed and incomplete cases stay visible.'])]
svg=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
 '<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#64748b"/></marker></defs>',
 '<rect width="100%" height="100%" fill="#f4f7fb"/>']
texts=[];rects=[];paths=[]

def text(x,y,value,size=19,color='#334155',bold=False):
    svg.append(f'<text x="{x}" y="{y}" font-family="Segoe UI, Arial, sans-serif" font-size="{size}" fill="{color}" font-weight="{700 if bold else 400}">{escape(value)}</text>')
    texts.append((x,y,value,size,color,bold))

def line(points,label=None,lx=0,ly=0):
    d='M '+' L '.join(f'{x} {y}' for x,y in points)
    svg.append(f'<path d="{d}" fill="none" stroke="#64748b" stroke-width="2" marker-end="url(#arrow)"/>')
    paths.append(points)
    if label: text(lx,ly,label,15,'#526177')

text(60,65,'Visual Cloud Platform | PostgreSQL OLTP',36,'#0f172a',True)
text(60,107,'24 tables / 33 foreign keys / 4 views',21)
for x,y,title,entities,notes in cards:
    svg.append(f'<rect x="{x}" y="{y}" width="420" height="250" rx="15" fill="white" stroke="#cbd5e1"/>')
    svg.append(f'<rect x="{x}" y="{y}" width="420" height="8" rx="4" fill="#2563eb"/>')
    rects.append((x,y,x+420,y+250))
    text(x+22,y+39,title,18,'#2563eb',True)
    for i,s in enumerate(entities): text(x+22,y+78+31*i,s,21,'#0f172a',True)
    for i,s in enumerate(notes): text(x+22,y+188+24*i,s,17)
line([(480,275),(530,275)])
line([(950,275),(1000,275)])
line([(1420,275),(1470,275)])
line([(270,560),(270,485),(1208,485),(1208,410)],'owned input / output references',595,469)
line([(1210,560),(1210,525),(1680,525),(1680,410)],'sealed choice before dispatch',1428,504)
line([(950,685),(1000,685)])
line([(1470,685),(1420,685)])
line([(1830,560),(1830,455),(1400,455),(1400,410)],'optional research condition',1485,441)
text(60,872,'Core flow: save a version → accept a launch → record a decision → dispatch an attempt → bind results and evidence',22,'#0f172a',True)
text(60,916,'schema_migrations stores structural history. Full fields, exact cardinalities and every FK: data-dictionary.md / logical-schema.mmd.',19)
text(60,948,'All supplied runs, forecasts, rates and measurements are synthetic fixtures. No AWS experiment or processor execution is claimed.',18,'#92400e')
svg.append('</svg>')
dest=ROOT/'docs/database';dest.mkdir(parents=True,exist_ok=True)
(dest/'schema-overview.svg').write_text('\n'.join(svg),encoding='utf-8')
