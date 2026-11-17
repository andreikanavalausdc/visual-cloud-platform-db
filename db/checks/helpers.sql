CREATE FUNCTION pg_temp.assert_true(label text,ok boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %',label; END IF;
  RAISE NOTICE 'PASS: %',label;
END $$;
CREATE FUNCTION pg_temp.expect_error(label text,statement text,expected_state text DEFAULT '23514',message_pattern text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE statement;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE<>expected_state OR (message_pattern IS NOT NULL AND SQLERRM !~ message_pattern) THEN
      RAISE EXCEPTION 'FAIL: %, expected % / %, got % / %',label,expected_state,message_pattern,SQLSTATE,SQLERRM;
    END IF;
    RAISE NOTICE 'PASS: %',label;
    RETURN;
  END;
  RAISE EXCEPTION 'FAIL: %, statement unexpectedly succeeded',label;
END $$;
