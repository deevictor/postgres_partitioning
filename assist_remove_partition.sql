--assist function to remove partitions
CREATE OR REPLACE FUNCTION remove_partitions(VARCHAR, INTEGER, INTEGER, INTEGER, INTEGER)
RETURNS void AS
$BODY$
DECLARE
  master_table      VARCHAR := $1;
  current_range     INTEGER := $2;
  range_interval    INTEGER := $3;
  number_to_keep    INTEGER := $4;
  number_to_drop    INTEGER := $5;

  max_range         INTEGER := current_range - range_interval * number_to_keep;
  min_range         INTEGER := max_range - range_interval * (number_to_drop - 1);
  partition_prefix  VARCHAR;
  child_table       VARCHAR;
  drop_table        VARCHAR;
BEGIN
  FOR range_to_drop IN REVERSE max_range .. min_range BY range_interval LOOP
    partition_prefix := to_char(range_to_drop::abstime, 'yymmdd');
    child_table := FORMAT('%s_%s', master_table, partition_prefix);

    IF EXISTS (SELECT 1 FROM pg_tables WHERE tablename = child_table) THEN
      drop_table := FORMAT('DROP TABLE %I', child_table);
      RAISE NOTICE 'dropping partition: %', child_table;
      EXECUTE drop_table;
    ELSE
      RAISE INFO 'Child table ''%'' does not exist. Nothing to delete.', child_table;
    END IF;
  END LOOP;
END
$BODY$
LANGUAGE plpgsql VOLATILE
COST 100;
-----------------------------------
ALTER FUNCTION remove_partitions(VARCHAR, INTEGER, INTEGER, INTEGER, INTEGER)
OWNER TO zabbix;