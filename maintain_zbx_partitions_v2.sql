CREATE OR REPLACE FUNCTION maintain_zbx_partitions(INTEGER DEFAULT 7) RETURNS VOID AS $$
DECLARE
  range_interval int := EXTRACT(epoch FROM '1 day'::INTERVAL);
  current_day_epoch int := EXTRACT(epoch FROM date_trunc('day', NOW()));

  archiveTables text[];
  create_partition text;
  apply_inheritance text;
  change_owner text;
  create_index text;
  update_trigger_function text;

  masterTable text;
  partition_prefix text;
  partition_name text;
  partition_name_array text[];
  index_name text;
  week_counter int;

  start_time int;
  start_time_array int[];
  end_time int;
  end_time_array int[];
  trigger_function_name text;

  partitions_number_to_keep int;
  partitions_number_to_drop int := $1;

BEGIN
  --Tables to create partitions for
  archiveTables = array['history', 'history_str', 'history_uint', 'trends', 'trends_uint'];

  FOR i in array_lower(archiveTables, 1)..array_upper(archiveTables, 1) LOOP
    RAISE NOTICE '==============================================================================================================================';
    masterTable := archiveTables[i];
    start_time_array := '{}';
    end_time_array := '{}';
    partition_name_array := '{}';
    --creating the partitions and updating the trigger functions for the the next week days
    FOR day_counter in 0..13 LOOP
      --constraints for created partition
      start_time := current_day_epoch + range_interval*day_counter;
      start_time_array := array_append(start_time_array, start_time);
      end_time := current_day_epoch + range_interval*(day_counter+1);
      end_time_array := array_append(end_time_array, end_time);
      --name of the created partition
      partition_prefix := to_char(start_time::abstime, 'yymmdd');

      partition_name := masterTable || '_' || partition_prefix;
      partition_name_array := array_append(partition_name_array, partition_name);
      index_name := partition_name || '_itemid_clock_idx';

      create_partition := FORMAT('CREATE TABLE %s (check (clock >= %s and clock < %s), like %s including defaults including storage) with oids',
        partition_name,
        start_time,
        end_time,
        masterTable);
      apply_inheritance := 'ALTER TABLE ' || partition_name || ' inherit ' || masterTable;
      change_owner := 'ALTER TABLE '||partition_name||' OWNER TO zabbix';
      create_index := 'CREATE INDEX ' || index_name || ' on ' || partition_name || '(itemid,clock)';

      IF EXISTS (SELECT 1 FROM pg_tables WHERE tablename = partition_name) THEN
        RAISE NOTICE 'Child table ''%'' already exist.', partition_name;

        EXECUTE change_owner;
      ELSE
        EXECUTE create_partition;
        EXECUTE change_owner;
        EXECUTE apply_inheritance;
        EXECUTE create_index;
        RAISE NOTICE 'partition % is created as a child of %', partition_name, masterTable;
      END IF;
    END LOOP;
    --update triggers for created partitions
    trigger_function_name := masterTable || '_trig_func()';
    RAISE NOTICE 'start_time_array: %', array_to_string(start_time_array, ',');
    RAISE NOTICE 'end_time_array: %', array_to_string(end_time_array, ',');
    RAISE NOTICE 'partition_name_array: %', array_to_string(partition_name_array, ',');
--building the update_trigger_function
    update_trigger_function := FORMAT('CREATE OR REPLACE FUNCTION %s
        RETURNS TRIGGER AS 
    $BODY$
      BEGIN
        IF TG_OP = ''INSERT'' THEN
          IF      NEW.clock >= %s AND NEW.clock < %s THEN
            INSERT INTO %I VALUES (NEW.*);',
      trigger_function_name,
      start_time_array[1],
      end_time_array[1],
      partition_name_array[1]);

    FOR day_counter1 in 2..14 LOOP
      update_trigger_function := FORMAT('%s
          ELSIF      NEW.clock >= %s AND NEW.clock < %s THEN
            INSERT  INTO %I VALUES (NEW.*);',
            update_trigger_function,
            start_time_array[day_counter1],
            end_time_array[day_counter1],
            partition_name_array[day_counter1]);
      END LOOP;
    update_trigger_function := FORMAT('%s
          ELSE    RETURN NEW;
        END IF;
      END IF;
      RETURN NULL;
    END
    $BODY$
    LANGUAGE plpgsql
    COST 100',
    update_trigger_function);
    EXECUTE update_trigger_function;
    RAISE NOTICE '% is updated as: %', trigger_function_name, update_trigger_function;
--remove old partitions
    IF masterTable IN ('trends', 'trends_uint') THEN
      partitions_number_to_keep = 90;
    ELSE
      partitions_number_to_keep = 30;
    END IF;
    PERFORM remove_partitions(masterTable, current_day_epoch, range_interval, partitions_number_to_keep, partitions_number_to_drop);
  END LOOP;
END
$$ LANGUAGE plpgsql;
-----------------------------------------------------------------------------------------
 ALTER FUNCTION maintain_zbx_partitions OWNER to zabbix;
-----------------------------------------------------------------------------------------
--create our triggers
CREATE TRIGGER history_trig        BEFORE INSERT ON history        FOR EACH ROW EXECUTE PROCEDURE history_trig_func();
CREATE TRIGGER history_str_trig    BEFORE INSERT ON history_str    FOR EACH ROW EXECUTE PROCEDURE history_str_trig_func();
CREATE TRIGGER history_uint_trig   BEFORE INSERT ON history_uint   FOR EACH ROW EXECUTE PROCEDURE history_uint_trig_func();
CREATE TRIGGER trends_trig         BEFORE INSERT ON trends         FOR EACH ROW EXECUTE PROCEDURE trends_trig_func();
CREATE TRIGGER trends_uint_trig    BEFORE INSERT ON trends_uint    FOR EACH ROW EXECUTE PROCEDURE trends_uint_trig_func();
-----------------------------------------------------------------------------------------
--adding dummy constraint to our master tables:
ALTER TABLE history