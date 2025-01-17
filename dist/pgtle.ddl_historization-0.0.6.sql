SELECT pgtle.install_extension
(
 'ddl_historization',
 '0.0.6',
 'DDL changes historization',
$_pg_tle_$
--
--
--

CREATE TABLE IF NOT EXISTS ddl_history (
  id serial primary key,
  ddl_date    timestamptz,      -- when the event occured
  objoid      oid,              -- the oid of the object
  objsubid    oid,              -- the oid of the column
  username    text,             -- the role used by the ddl command
  ddl_tag     text,
  object_name text,
  otype       text,             -- the object type
  ddl_command text,             -- the original statement that triggered
  trg_name    text,
  txid        bigint            -- the transaction id
);

--
--
--
CREATE TABLE IF NOT EXISTS ddl_history_column (
  attrelid      oid NOT NULL,
  attnum        smallint NOT NULL,
  tablename     name NOT NULL,
  columnname    name NOT NULL,
  creation_time timestamp with time zone DEFAULT current_timestamp,
  create_by     text DEFAULT current_user
);

CREATE UNIQUE INDEX ON ddl_history_column (tablename, columnname);

--
-- View dedicated to consult the comment on all objects
--
CREATE OR REPLACE VIEW ddl_history_comment AS
SELECT
  h.id,
  h.objoid,
  h.ddl_date,
  h.username,
  h.object_name,
  h.otype,
  h.trg_name,
  d.description
  FROM ddl_history h
  JOIN pg_catalog.pg_description d ON d.objoid=h.objoid
  WHERE ddl_tag = 'COMMENT'
;

GRANT INSERT,SELECT ON ddl_history TO PUBLIC;
GRANT USAGE ON ddl_history_id_seq TO PUBLIC;
-- Log ddl changes on non DROP actions
--
--
CREATE OR REPLACE FUNCTION log_ddl()
  RETURNS event_trigger AS $$
DECLARE
  r RECORD;
  s TEXT;
BEGIN
  s := current_query();

  FOR r IN SELECT * FROM pg_event_trigger_ddl_commands()
  LOOP
     INSERT INTO @extschema@.ddl_history
     (ddl_date, objoid, objsubid, ddl_tag, object_name, ddl_command, otype, username, trg_name, txid)
     VALUES
     (statement_timestamp(), r.objid, r.objsubid, tg_tag, r.object_identity, s, r.object_type, current_user, 'command_end', txid_current() );
     --
     -- log columns for new tables
     --
     IF tg_tag = 'CREATE TABLE' AND r.object_type = 'table' THEN
       INSERT INTO @extschema@.ddl_history_column (attrelid, tablename, columnname, attnum)
       SELECT attrelid, r.object_identity, attname, attnum FROM pg_attribute
       WHERE attnum > 0 AND attrelid = r.objid;
     END IF;

     IF tg_tag = 'ALTER TABLE' AND r.object_type = 'table' THEN
       INSERT INTO @extschema@.ddl_history_column (attrelid, tablename, columnname, attnum)
       SELECT attrelid, r.object_identity, attname, attnum FROM pg_attribute
       WHERE attnum > 0 AND NOT attisdropped AND attrelid = r.objid
       ON CONFLICT DO NOTHING;
     END IF;

  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Log ddl changes on DROP actions
--
--
CREATE OR REPLACE FUNCTION log_ddl_drop()

  RETURNS event_trigger AS $$

DECLARE
  r RECORD;
  s TEXT;
BEGIN
  s := current_query();
  FOR r IN SELECT * FROM pg_event_trigger_dropped_objects()
    LOOP
      INSERT INTO @extschema@.ddl_history (ddl_date, objoid, objsubid, ddl_tag, object_name, ddl_command, otype, username, trg_name, txid )
      VALUES (statement_timestamp(), r.objid, r.objsubid, tg_tag, r.object_identity, s, r.object_type, current_user, 'sql_drop', txid_current() );
     --
     -- drop table
     --
     IF tg_tag = 'DROP TABLE' AND r.object_type = 'table' THEN
       DELETE FROM @extschema@.ddl_history_column WHERE tablename = r.object_identity;
     END IF;
     --
     -- alter table drop column
     --
     IF tg_tag = 'ALTER TABLE' AND r.object_type = 'table column' THEN
       DELETE FROM @extschema@.ddl_history_column WHERE attrelid = r.objid AND attnum=r.objsubid;
     END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
--
--
--
CREATE OR REPLACE FUNCTION log_ddl_start()
  RETURNS void AS $$
DECLARE
  schemaname TEXT;
BEGIN
  SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace WHERE e.extname='ddl_historization' INTO schemaname;

  EXECUTE format('
        CREATE EVENT TRIGGER log_ddl_info
        ON ddl_command_end
        EXECUTE FUNCTION %s.log_ddl()', schemaname);

  EXECUTE format('
        CREATE EVENT TRIGGER log_ddl_drop_info
        ON sql_drop
        EXECUTE FUNCTION %s.log_ddl_drop()', schemaname);
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION log_ddl_stop()
  RETURNS void AS $$
BEGIN
        EXECUTE format('DROP EVENT TRIGGER IF EXISTS log_ddl_info');
        EXECUTE format('DROP EVENT TRIGGER IF EXISTS log_ddl_drop_info');
END;
$$ LANGUAGE plpgsql;
--
-- Automatically start the historization at the end of install.
--
SELECT @extschema@.log_ddl_start();
$_pg_tle_$
);
