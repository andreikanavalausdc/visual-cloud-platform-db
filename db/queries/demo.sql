\set ON_ERROR_STOP on

SET ROLE vcp_read;
SELECT * FROM app.v_users_masked ORDER BY id;
SELECT name,version_no,status,data_origin,priority,end_to_end_ms,modeled_cost,verification,output_count
  FROM app.v_run_summary ORDER BY accepted_at;
SELECT * FROM app.v_result_metadata ORDER BY run_id;
SELECT mode,dataset_split,data_origin,attempts,failed,verified_correct,unverified,missing_cost,median_correct_ms,mean_correct_cost
  FROM app.v_research_comparison ORDER BY dataset_split,mode;
RESET ROLE;
