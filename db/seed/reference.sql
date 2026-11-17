\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE vcp_admin;
INSERT INTO app.operation_versions(code,version,input_kind,output_kind,parameter_contract,description) VALUES
('csv.validate',1,'csv','csv','{"type":"object","required":["required_columns"],"properties":{"required_columns":{"type":"array","minItems":1,"items":{"type":"string","minLength":1}}},"additionalProperties":false}', 'Check required CSV column names; execution processor is not implemented in this package'),
('csv.filter',1,'csv','csv','{"type":"object","required":["column","operator","value"],"properties":{"column":{"type":"string","minLength":1},"operator":{"enum":["gt","lt","eq"]},"value":{"type":"number"}},"additionalProperties":false}', 'Filter numeric values under declared comparison'),
('csv.transform',1,'csv','csv','{"type":"object","required":["source","target"],"properties":{"source":{"type":"string","minLength":1},"target":{"type":"string","minLength":1}},"additionalProperties":false}', 'Rename a column; source and target must differ'),
('csv.export',1,'csv','csv','{"type":"object","required":["delimiter"],"properties":{"delimiter":{"enum":[",",";"]}},"additionalProperties":false}', 'Export CSV with declared delimiter');
INSERT INTO app.runtime_configurations(environment,version_no,region,execution_model,cpu_units,memory_mib,settings) VALUES
('worker',1,'synthetic-region','synthetic persistent process',1024,512,'{"synthetic":true}'),
('lambda',1,'synthetic-region','synthetic on-demand invocation',1024,512,'{"synthetic":true}'),
('fargate',1,'synthetic-region','synthetic run-task container',1024,2048,'{"synthetic":true}');
INSERT INTO app.selection_policy_versions(code,version_no,definition) VALUES
('demo-policy',1,'{"synthetic":true,"description":"Seed fixtures only. Not a calibrated selection algorithm.","fallback":"eligible configured worker"}');
INSERT INTO app.cost_model_versions(code,version_no,currency,rate_date,accounting_scope,rates) VALUES
('synthetic-usd',1,'USD','2026-11-15','Synthetic compute + launch + coordination + storage/transfer + logging; API/database hosting excluded; worker idle explicitly allocated',
 '{"synthetic":true,"task_cost":0.0001,"run_overhead":0.0001,"worker_idle_per_run":0.0002}');
INSERT INTO app.experiment_conditions(scenario,input_volume,arrival_pattern,mode,dataset_split,fixture_key,protocol_version)
SELECT 'csv','small','isolated',m,'evaluation','synthetic-csv-A','demo-v1'
FROM unnest(ARRAY['worker_only','lambda_only','fargate_only','auto_balanced','auto_fastest','auto_cheapest']) m;
INSERT INTO app.experiment_conditions(scenario,input_volume,arrival_pattern,mode,dataset_split,fixture_key,protocol_version)
VALUES ('csv','small','isolated','worker_only','calibration','synthetic-csv-calibration','demo-v1');
COMMIT;
