-- Enforce extension execution
\echo Use "CREATE EXTENSION pg_creation_tracker" to load this file. \quit

-- 1. Table creation log
CREATE TABLE object_creation_log (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    database_name TEXT NOT NULL,
    schema_name TEXT NOT NULL,
    object_name TEXT NOT NULL,
    object_type TEXT NOT NULL,
    object_oid OID UNIQUE,
    creation_time TIMESTAMPTZ,
    recorded_time TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    detection_method TEXT DEFAULT 'EVENT_TRIGGER'
);

-- 2. Helper function to find physical database directory safely across default & custom tablespaces
CREATE OR REPLACE FUNCTION get_database_creation_time(p_datname text, p_db_oid oid, p_spc_oid oid)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_path text;
    v_stat record;
    v_version text;
BEGIN
    -- If default tablespace (pg_default, oid 1663), it is in base/<db_oid>
    IF p_spc_oid = 1663 OR p_spc_oid = 0 THEN
        v_path := 'base/' || p_db_oid;
    ELSE
        -- Custom tablespace: resolve pg_tblspc symlink
        -- PG 17 catalogs catalog version string
        SELECT 'PG_17_' || split_part(version(), ' ', 2) INTO v_version;
        v_path := 'pg_tblspc/' || p_spc_oid;
    END IF;

    BEGIN
        SELECT modification INTO v_stat FROM pg_stat_file(v_path);
        RETURN v_stat.modification;
    EXCEPTION WHEN OTHERS THEN
        -- Fallback to base/ directory check
        BEGIN
            SELECT modification INTO v_stat FROM pg_stat_file('base/' || p_db_oid);
            RETURN v_stat.modification;
        EXCEPTION WHEN OTHERS THEN
            RETURN NULL;
        END;
    END;
END;
$$;

-- 3. View for Database-level creation timestamps
CREATE OR REPLACE VIEW database_creation_info AS
SELECT 
    d.oid AS database_oid,
    d.datname AS database_name,
    t.spcname AS tablespace_name,
    @extschema@.get_database_creation_time(d.datname, d.oid, d.dattablespace) AS creation_time,
    CASE 
        WHEN @extschema@.get_database_creation_time(d.datname, d.oid, d.dattablespace) IS NOT NULL 
        THEN 'FILESYSTEM_DIRECTORY_METADATA'
        ELSE 'UNAVAILABLE'
    END AS detection_method
FROM pg_database d
JOIN pg_tablespace t ON t.oid = d.dattablespace;

-- 4. Backfill function for existing tables created before the extension
CREATE OR REPLACE FUNCTION backfill_existing_tables()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    r RECORD;
    v_count integer := 0;
    v_ts timestamptz;
    v_method text;
    v_stat record;
    v_child_ts timestamptz;
BEGIN
    FOR r IN
        SELECT 
            c.oid AS table_oid,
            n.nspname AS schema_name,
            c.relname AS table_name,
            c.relkind,
            c.relfilenode,
            c.xmin,
            pg_relation_filepath(c.oid) AS filepath
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'timestamp_tracking')
          AND c.relkind IN ('r', 'p')
          AND NOT EXISTS (
              SELECT 1 FROM @extschema@.object_creation_log l WHERE l.object_oid = c.oid
          )
    LOOP
        v_ts := NULL;
        v_method := 'UNKNOWN';

        -- Attempt 1: Transaction commit timestamp
        BEGIN
            v_ts := pg_xact_commit_timestamp(r.xmin);
            IF v_ts IS NOT NULL THEN
                v_method := 'COMMIT_TIMESTAMP';
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_ts := NULL;
        END;

        -- Attempt 2: Partitioned table estimate via earliest child
        IF v_ts IS NULL AND r.relkind = 'p' THEN
            BEGIN
                SELECT min(s.modification) INTO v_child_ts
                FROM pg_inherits i
                JOIN pg_class child ON child.oid = i.inhrelid
                CROSS JOIN LATERAL pg_stat_file(pg_relation_filepath(child.oid)) s
                WHERE i.inhparent = r.table_oid;

                IF v_child_ts IS NOT NULL THEN
                    v_ts := v_child_ts;
                    v_method := 'PARTITION_EARLIEST_CHILD_ESTIMATE';
                END IF;
            EXCEPTION WHEN OTHERS THEN
                v_ts := NULL;
            END;
        END IF;

        -- Attempt 3: Filesystem relation file check
        IF v_ts IS NULL AND r.filepath IS NOT NULL THEN
            BEGIN
                SELECT modification INTO v_stat FROM pg_stat_file(r.filepath);
                IF r.relfilenode = r.table_oid THEN
                    v_ts := v_stat.modification;
                    v_method := 'FILESYSTEM_UNMODIFIED';
                ELSE
                    v_ts := v_stat.modification;
                    v_method := 'REWRITTEN_STORAGE_ESTIMATE';
                END IF;
            EXCEPTION WHEN OTHERS THEN
                v_ts := NULL;
            END;
        END IF;

        INSERT INTO @extschema@.object_creation_log (
            database_name,
            schema_name,
            object_name,
            object_type,
            object_oid,
            creation_time,
            recorded_time,
            detection_method
        )
        VALUES (
            current_database(),
            r.schema_name,
            r.schema_name || '.' || r.table_name,
            'table',
            r.table_oid,
            v_ts,
            clock_timestamp(),
            v_method
        )
        ON CONFLICT (object_oid) DO NOTHING;

        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;

-- 5. Event trigger function for future table creation
CREATE OR REPLACE FUNCTION capture_table_creation()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    cmd RECORD;
BEGIN
    FOR cmd IN
        SELECT *
        FROM pg_event_trigger_ddl_commands()
    LOOP
        IF cmd.object_type IN ('table', 'foreign table')
           AND cmd.schema_name IS NOT NULL
           AND cmd.schema_name NOT IN ('pg_catalog', 'information_schema', 'timestamp_tracking')
           AND cmd.schema_name NOT LIKE 'pg_temp_%'
           AND cmd.schema_name NOT LIKE 'pg_toast%'
           AND NOT cmd.in_extension
        THEN
            INSERT INTO @extschema@.object_creation_log (
                database_name,
                schema_name,
                object_name,
                object_type,
                object_oid,
                creation_time,
                recorded_time,
                detection_method
            )
            VALUES (
                current_database(),
                cmd.schema_name,
                cmd.object_identity,
                cmd.object_type,
                cmd.objid,
                statement_timestamp(),
                clock_timestamp(),
                'EVENT_TRIGGER'
            )
            ON CONFLICT (object_oid) DO NOTHING;
        END IF;
    END LOOP;
END;
$$;

-- 6. Run backfill on installation
SELECT backfill_existing_tables();

-- 7. Register table creation event trigger
CREATE EVENT TRIGGER capture_table_creation_trigger
ON ddl_command_end
EXECUTE FUNCTION capture_table_creation();
