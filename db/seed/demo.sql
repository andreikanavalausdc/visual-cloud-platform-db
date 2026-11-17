\set ON_ERROR_STOP on

BEGIN;
SET LOCAL ROLE vcp_admin;
DO $$
DECLARE alice uuid; bob uuid; wf uuid; v uuid; v2 uuid; input_a uuid; input_b uuid;
  policy uuid; costmodel uuid; c record; n record; k integer; trial integer;
  run uuid; ex uuid; dec uuid; candidate uuid; chosen uuid; att uuid; output uuid;
  calibration uuid; env text; priority text; unavailable boolean; rejected boolean;
BEGIN
  INSERT INTO app.users(email,display_name) VALUES('alice@example.invalid','Synthetic Alice') RETURNING id INTO alice;
  INSERT INTO app.users(email,display_name) VALUES('bob@example.invalid','Synthetic Bob') RETURNING id INTO bob;
  
  INSERT INTO app.user_credentials(user_id,password_hash) VALUES
    (alice,'$pbkdf2-sha256$600000$vDOznW1J/wipuw2nVIe6+w==$BLgKfZ/TkoYVsH2omYmkM2mFQtbfv/skJEmRSirH7S0=');
  INSERT INTO app.workflows(owner_id,name) VALUES(alice,'Synthetic CSV pipeline') RETURNING id INTO wf;
  INSERT INTO app.workflow_versions(workflow_id,version_no) VALUES(wf,1) RETURNING id INTO v;
  INSERT INTO app.workflow_nodes(version_id,node_key,operation_version_id,parameters,position_x)
    SELECT v,split_part(code,'.',2),id,
      CASE code WHEN 'csv.validate' THEN '{"required_columns":["id","value"]}'::jsonb
        WHEN 'csv.filter' THEN '{"column":"value","operator":"gt","value":0}'::jsonb
        WHEN 'csv.transform' THEN '{"source":"value","target":"amount"}'::jsonb
        ELSE '{"delimiter":","}'::jsonb END,
      CASE code WHEN 'csv.validate' THEN 0 WHEN 'csv.filter' THEN 200 WHEN 'csv.transform' THEN 400 ELSE 600 END
    FROM app.operation_versions;
  INSERT INTO app.workflow_edges(version_id,source_node_id,target_node_id)
    SELECT v,s.id,t.id FROM app.workflow_nodes s JOIN app.workflow_nodes t ON t.version_id=s.version_id
    WHERE s.version_id=v AND (s.node_key,t.node_key) IN (('validate','filter'),('filter','transform'),('transform','export'));
  UPDATE app.workflow_versions SET published_at=clock_timestamp() WHERE id=v;
  INSERT INTO app.artifacts(owner_id,storage_key,original_name,media_kind,size_bytes,sha256,state)
    VALUES(alice,'synthetic://alice/input-a','input-a.csv','csv',1000,repeat('a',64),'complete') RETURNING id INTO input_a;
  INSERT INTO app.artifacts(owner_id,storage_key,original_name,media_kind,size_bytes,sha256,state)
    VALUES(alice,'synthetic://alice/input-b','input-b.csv','csv',1100,repeat('b',64),'complete') RETURNING id INTO input_b;
  INSERT INTO app.artifacts(owner_id,storage_key,original_name,media_kind,size_bytes,sha256,state)
    VALUES(bob,'synthetic://bob/private','private.csv','csv',1000,repeat('c',64),'complete');
  SELECT id INTO policy FROM app.selection_policy_versions WHERE code='demo-policy';
  SELECT id INTO costmodel FROM app.cost_model_versions WHERE code='synthetic-usd';
  
  FOR c IN SELECT * FROM app.experiment_conditions ORDER BY (dataset_split='calibration') DESC,mode LOOP
    env:=CASE c.mode WHEN 'lambda_only' THEN 'lambda' WHEN 'fargate_only' THEN 'fargate'
      WHEN 'auto_fastest' THEN 'lambda' WHEN 'auto_cheapest' THEN 'lambda' ELSE 'worker' END;
    priority:=CASE c.mode WHEN 'auto_fastest' THEN 'fastest' WHEN 'auto_cheapest' THEN 'cheapest' ELSE 'balanced' END;
    FOR trial IN 1..CASE WHEN c.dataset_split='calibration' THEN 1 ELSE 2 END LOOP
      run:=app.create_run(v,CASE WHEN trial=1 THEN input_a ELSE input_b END,policy,priority,gen_random_uuid(),'synthetic',c.id,trial);
      UPDATE app.workflow_runs SET status='running',started_at=clock_timestamp() WHERE id=run;
      rejected:=(c.mode='auto_cheapest' AND trial=2);
      FOR n IN SELECT e.id AS exid,x.node_key,x.position_x FROM app.node_executions e JOIN app.workflow_nodes x ON x.id=e.node_id
        WHERE e.run_id=run ORDER BY x.position_x LOOP
        ex:=n.exid;
        UPDATE app.node_executions SET status='running' WHERE id=ex;
        FOR k IN 1..CASE WHEN c.mode='auto_balanced' AND trial=2 AND n.node_key='validate' THEN 2 ELSE 1 END LOOP
          INSERT INTO app.selection_decisions(execution_id,attempt_no,explanation)
            VALUES(ex,k,'Synthetic selection fixture; not a measured runtime recommendation') RETURNING id INTO dec;
          chosen:=NULL;
          FOR candidate IN SELECT id FROM app.runtime_configurations LOOP
            INSERT INTO app.decision_candidates(decision_id,runtime_configuration_id,eligible,exclusion_reason,predicted_ms,predicted_cost,cost_model_id,uncertainty_note)
              VALUES(dec,candidate,NOT rejected,CASE WHEN rejected THEN 'Synthetic unavailable environment' END,100,0.0001,costmodel,'Synthetic forecast, no numerical confidence claim')
              RETURNING id INTO att;
            IF (SELECT environment FROM app.runtime_configurations WHERE id=candidate)=env THEN chosen:=att; END IF;
            IF calibration IS NOT NULL AND (SELECT environment FROM app.runtime_configurations WHERE id=candidate)='worker' THEN
              INSERT INTO app.candidate_evidence_links(candidate_id,calibration_run_id) VALUES(att,calibration);
            END IF;
          END LOOP;
          IF rejected THEN chosen:=NULL; END IF;
          UPDATE app.selection_decisions SET selected_candidate_id=chosen,is_fallback=(chosen IS NOT NULL AND env='lambda'),sealed_at=clock_timestamp() WHERE id=dec;
          IF rejected THEN EXIT; END IF;
          INSERT INTO app.task_attempts(decision_id) VALUES(dec) RETURNING id INTO att;
          UPDATE app.task_attempts SET status='running',dispatch_reference='synthetic://attempt/'||att,started_at=clock_timestamp() WHERE id=att;
          IF c.mode='auto_balanced' AND trial=2 AND n.node_key='validate' AND k=1 THEN
            UPDATE app.task_attempts SET status='failed',finished_at=clock_timestamp(),error_code='SYNTHETIC_TRANSIENT',safe_error_message='Synthetic retry example' WHERE id=att;
          ELSE
            UPDATE app.task_attempts SET status='succeeded',finished_at=clock_timestamp() WHERE id=att;
          END IF;
          INSERT INTO app.task_measurements(attempt_id,processing_ms,modeled_cost,cost_model_id,unavailable_reason)
            VALUES(att,100,0.0001,costmodel,'CPU and RAM utilization not collected in this synthetic fixture');
        END LOOP;
        IF rejected THEN
          UPDATE app.node_executions SET status='failed' WHERE id=ex;
          EXIT;
        END IF;
        UPDATE app.node_executions SET status='succeeded' WHERE id=ex;
      END LOOP;
      IF rejected THEN
        UPDATE app.workflow_runs SET status='failed',finished_at=clock_timestamp(),error_code='NO_ELIGIBLE_RUNTIME' WHERE id=run;
      ELSE
        INSERT INTO app.artifacts(owner_id,storage_key,original_name,media_kind,size_bytes,sha256,state)
          VALUES(alice,'synthetic://result/'||run,'result.csv','csv',900,repeat('d',64),'complete') RETURNING id INTO output;
        INSERT INTO app.task_artifacts(attempt_id,artifact_id,direction,port_name) VALUES(att,output,'output','result');
        INSERT INTO app.run_results(run_id,artifact_id,source_attempt_id) VALUES(run,output,att);
        UPDATE app.workflow_runs SET status='succeeded',finished_at=clock_timestamp() WHERE id=run;
        INSERT INTO app.run_verifications(run_id,outcome,checker_version,expected_result_key,note)
          VALUES(run,'passed','synthetic-checker-v1','synthetic-expected-csv','Fixture of a passed check, not an executed processor test');
      END IF;
      unavailable:=(c.mode='auto_fastest' AND trial=2);
      INSERT INTO app.run_measurements(run_id,end_to_end_ms,modeled_cost,cost_model_id,observation_window_start,observation_window_end,allocated_idle_cost,unavailable_reason)
        VALUES(run,CASE WHEN rejected THEN 50 ELSE 1000+trial*10 END,
          CASE WHEN unavailable THEN NULL ELSE (SELECT coalesce(sum(m.modeled_cost),0) FROM app.task_measurements m
            JOIN app.task_attempts a ON a.id=m.attempt_id JOIN app.selection_decisions d ON d.id=a.decision_id
            JOIN app.node_executions e ON e.id=d.execution_id WHERE e.run_id=run)+0.0001+CASE WHEN env='worker' THEN 0.0002 ELSE 0 END END,
          costmodel,CASE WHEN env='worker' THEN clock_timestamp()-interval '1 hour' END,
          CASE WHEN env='worker' THEN clock_timestamp() END,CASE WHEN env='worker' THEN 0.0002 END,
          CASE WHEN unavailable THEN 'Synthetic missing cost example' END);
      IF c.dataset_split='calibration' THEN calibration:=run; END IF;
    END LOOP;
  END LOOP;
  
  INSERT INTO app.workflow_versions(workflow_id,version_no) VALUES(wf,2) RETURNING id INTO v2;
  INSERT INTO app.workflow_nodes(version_id,node_key,operation_version_id,parameters,position_x,position_y)
    SELECT v2,node_key,operation_version_id,CASE WHEN node_key='filter' THEN jsonb_set(parameters,'{value}','10') ELSE parameters END,position_x,position_y
    FROM app.workflow_nodes WHERE version_id=v;
  INSERT INTO app.workflow_edges(version_id,source_node_id,target_node_id)
    SELECT v2,ns.id,nt.id FROM app.workflow_edges e JOIN app.workflow_nodes os ON os.id=e.source_node_id
      JOIN app.workflow_nodes ot ON ot.id=e.target_node_id JOIN app.workflow_nodes ns ON ns.version_id=v2 AND ns.node_key=os.node_key
      JOIN app.workflow_nodes nt ON nt.version_id=v2 AND nt.node_key=ot.node_key WHERE e.version_id=v;
  UPDATE app.workflow_versions SET published_at=clock_timestamp() WHERE id=v2;
END $$;
COMMIT;
