cat << 'EOF' > /root/pg_creation_tracker/pg_track--1.0.sql
-- Enforce extension execution
\echo Use "CREATE EXTENSION pg_track" to load this file. \quit

-- 1. Main log table for all database objects
CREATE TABLE objects (
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

-- 2. Helper function to find physical database creation time via PG_VERSION
CREATE OR REPLACE FUNCTION get_database_creation_time(p_datname text, p_db_oid oid, p_spc_oid oid)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_path text;
    v_stat record;
    v_ver_dir text;
BEGIN
    -- 1. Default tablespaces (pg_default = 1663 or pg_global = 1664 or 0)
    IF p_spc_oid = 1663 OR p_spc_oid = 1664 OR p_spc_oid = 0 THEN
        v_path := 'base/' || p_db_oid || '/PG_VERSION';
    ELSE
        -- 2. Custom tablespace: resolve pg_tblspc version directory
        BEGIN
            SELECT entry INTO v_ver_dir
            FROM pg_ls_dir('pg_tblspc/' || p_spc_oid) entry
            WHERE entry LIKE 'PG_%'
            LIMIT 1;

            IF v_ver_dir IS NOT NULL THEN
                v_path := 'pg_tblspc/' || p_spc_oid || '/' || v_ver_dir || '/' || p_db_oid || '/PG_VERSION';
            ELSE
                v_path := 'base/' || p_db_oid || '/PG_VERSION';
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_path := 'base/' || p_db_oid || '/PG_VERSION';
        END;
    END IF;

    -- Attempt 1: Read modification time of PG_VERSION
    BEGIN
        SELECT modification INTO v_stat FROM pg_stat_file(v_path);
        IF v_stat IS NOT NULL THEN
            RETURN v_stat.modification;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    -- Attempt 2: Fallback to base directory
    BEGIN
        SELECT modification INTO v_stat FROM pg_stat_file('base/' || p_db_oid);
        RETURN v_stat.modification;
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END;
END;
$$;

-- 3. Database creation view (track.databases)
CREATE OR REPLACE VIEW databases AS
SELECT 
    d.oid AS database_oid,
    d.datname AS database_name,
    t.spcname AS tablespace_name,
    @extschema@.get_database_creation_time(d.datname, d.oid, d.dattablespace) AS creation_time,
    CASE 
        WHEN @extschema@.get_database_creation_time(d.datname, d.oid, d.dattablespace) IS NOT NULL 
        THEN 'FILESYSTEM_PG_VERSION_METADATA'
        ELSE 'UNAVAILABLE'
    END AS detection_method
FROM pg_database d
JOIN pg_tablespace t ON t.oid = d.dattablespace;

-- 4. Convenient shortcut views
CREATE OR REPLACE VIEW tables AS
SELECT id, schema_name, object_name, creation_time, detection_method
FROM @extschema@.objects
WHERE object_type IN ('table', 'partitioned table');

CREATE OR REPLACE VIEW indexes AS
SELECT id, schema_name, object_name, creation_time, detection_method
FROM @extschema@.objects
WHERE object_type IN ('index', 'partitioned index');

CREATE OR REPLACE VIEW schemas AS
SELECT id, object_name AS schema_name, creation_time, detection_method
FROM @extschema@.objects
WHERE object_type = 'schema';

-- 5. Backfill function for existing tables, indexes, and schemas
CREATE OR REPLACE FUNCTION backfill_existing_objects()
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
    -- A. Backfill Existing Schemas
    FOR r IN
        SELECT 
            n.oid AS schema_oid,
            n.nspname AS schema_name,
            n.xmin
        FROM pg_namespace n
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND n.nspname != current_schema()
          AND n.nspname NOT LIKE 'pg_temp_%'
          AND NOT EXISTS (
              SELECT 1 FROM @extschema@.objects l WHERE l.object_oid = n.oid
          )
    LOOP
        v_ts := NULL;
        v_method := 'UNKNOWN';

        BEGIN
            v_ts := pg_xact_commit_timestamp(r.xmin);
            IF v_ts IS NOT NULL THEN
                v_method := 'COMMIT_TIMESTAMP';
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_ts := NULL;
        END;

        INSERT INTO @extschema@.objects (
            database_name, schema_name, object_name, object_type, object_oid,
            creation_time, recorded_time, detection_method
        )
        VALUES (
            current_database(), r.schema_name, r.schema_name, 'schema', r.schema_oid,
            v_ts, clock_timestamp(), v_method
        )
        ON CONFLICT (object_oid) DO NOTHING;

        v_count := v_count + 1;
    END LOOP;

    -- B. Backfill Existing Tables and Indexes
    FOR r IN
        SELECT 
            c.oid AS object_oid,
            n.nspname AS schema_name,
            c.relname AS object_name,
            CASE 
                WHEN c.relkind = 'r' THEN 'table'
                WHEN c.relkind = 'p' THEN 'partitioned table'
                WHEN c.relkind = 'i' THEN 'index'
                WHEN c.relkind = 'I' THEN 'partitioned index'
            END AS object_type,
            c.relkind,
            c.relfilenode,
            c.xmin,
            pg_relation_filepath(c.oid) AS filepath
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND n.nspname != current_schema()
          AND c.relkind IN ('r', 'p', 'i', 'I')
          AND NOT EXISTS (
              SELECT 1 FROM @extschema@.objects l WHERE l.object_oid = c.oid
          )
    LOOP
        v_ts := NULL;
        v_method := 'UNKNOWN';

        BEGIN
            v_ts := pg_xact_commit_timestamp(r.xmin);
            IF v_ts IS NOT NULL THEN
                v_method := 'COMMIT_TIMESTAMP';
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_ts := NULL;
        END;

        IF v_ts IS NULL AND r.relkind IN ('p', 'I') THEN
            BEGIN
                SELECT min(s.modification) INTO v_child_ts
                FROM pg_inherits i
                JOIN pg_class child ON child.oid = i.inhrelid
                CROSS JOIN LATERAL pg_stat_file(pg_relation_filepath(child.oid)) s
                WHERE i.inhparent = r.object_oid;

                IF v_child_ts IS NOT NULL THEN
                    v_ts := v_child_ts;
                    v_method := 'PARTITION_EARLIEST_CHILD_ESTIMATE';
                END IF;
            EXCEPTION WHEN OTHERS THEN
                v_ts := NULL;
            END;
        END IF;

        IF v_ts IS NULL AND r.filepath IS NOT NULL THEN
            BEGIN
                SELECT modification INTO v_stat FROM pg_stat_file(r.filepath);
                IF r.relfilenode = r.object_oid THEN
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

        INSERT INTO @extschema@.objects (
            database_name, schema_name, object_name, object_type, object_oid,
            creation_time, recorded_time, detection_method
        )
        VALUES (
            current_database(),
            r.schema_name,
            r.schema_name || '.' || r.object_name,
            r.object_type,
            r.object_oid,
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

-- 6. Event trigger function for real-time tracking
CREATE OR REPLACE FUNCTION capture_object_creation()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    cmd RECORD;
    v_schema TEXT;
BEGIN
    FOR cmd IN
        SELECT *
        FROM pg_event_trigger_ddl_commands()
    LOOP
        IF cmd.object_type IN ('table', 'foreign table', 'index') THEN
            IF cmd.schema_name IS NOT NULL
               AND cmd.schema_name NOT IN ('pg_catalog', 'information_schema')
               AND cmd.schema_name != current_schema()
               AND cmd.schema_name NOT LIKE 'pg_temp_%'
               AND cmd.schema_name NOT LIKE 'pg_toast%'
               AND NOT cmd.in_extension
            THEN
                INSERT INTO @extschema@.objects (
                    database_name, schema_name, object_name, object_type, object_oid,
                    creation_time, recorded_time, detection_method
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

        ELSIF cmd.object_type = 'schema' THEN
            v_schema := cmd.object_identity;
            IF v_schema NOT IN ('pg_catalog', 'information_schema')
               AND v_schema != current_schema()
               AND v_schema NOT LIKE 'pg_temp_%'
               AND v_schema NOT LIKE 'pg_toast%'
               AND NOT cmd.in_extension
            THEN
                INSERT INTO @extschema@.objects (
                    database_name, schema_name, object_name, object_type, object_oid,
                    creation_time, recorded_time, detection_method
                )
                VALUES (
                    current_database(),
                    v_schema,
                    v_schema,
                    'schema',
                    cmd.objid,
                    statement_timestamp(),
                    clock_timestamp(),
                    'EVENT_TRIGGER'
                )
                ON CONFLICT (object_oid) DO NOTHING;
            END IF;
        END IF;
    END LOOP;
END;
$$;

-- 7. Run backfill on installation
SELECT backfill_existing_objects();

-- 8. Register DDL event trigger
CREATE EVENT TRIGGER capture_object_creation_trigger
ON ddl_command_end
EXECUTE FUNCTION capture_object_creation();
EOF
