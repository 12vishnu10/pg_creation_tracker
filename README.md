# pg_creation_tracker

Automated PostgreSQL database and table creation timestamp tracker.

PostgreSQL system catalogs (`pg_class`, `pg_database`) do not natively maintain an object creation timestamp. `pg_creation_tracker` solves this limitation by providing:
- **Live DDL Audit:** Captures real-time table creation timestamps via native Event Triggers.
- **Forensic Historical Backfill:** Recovers creation timestamps for tables created prior to extension installation using commit logs, partition hierarchies, and storage metadata.
- **Database Creation Auditing:** Tracks creation timestamps for all databases in the cluster across standard and custom tablespaces.
- **Zero External Dependencies:** Pure SQL and PL/pgSQL. No C compiler or development headers required.

---

## Installation

### Method 1: From Source (PGXS Make)
Ensure `pg_config` is in your `PATH` (e.g., `export PATH=/usr/pgsql-17/bin:$PATH`):

```bash
git clone [https://github.com/12vishnu10/pg_creation_tracker.git](https://github.com/12vishnu10/pg_creation_tracker.git)
cd pg_creation_tracker
make
sudo make install
Method 2: From Pre-Built RPM (RHEL / Rocky / AlmaLinux)Download the .rpm release asset and install:Bashsudo dnf install -y pg_creation_tracker17-1.0-1.el10.noarch.rpm
Setup & Activation1. Enable Cluster-Wide Inheritance (Recommended)Installing in template1 ensures every future database created with CREATE DATABASE automatically inherits the tracker:SQL\c template1
CREATE EXTENSION pg_creation_tracker;
2. Enable in an Existing DatabaseSQL\c your_database
CREATE EXTENSION pg_creation_tracker;
How to Query & Use1. Query Table Creation TimestampsSQLSELECT 
    id,
    schema_name,
    object_name,
    creation_time,
    recorded_time,
    detection_method
FROM timestamp_tracking.object_creation_log
ORDER BY id;
2. Query Database Creation TimestampsSQLSELECT 
    database_oid,
    database_name,
    tablespace_name,
    creation_time,
    detection_method
FROM timestamp_tracking.database_creation_info;
Columns & Data DictionaryTable: timestamp_tracking.object_creation_logColumnData TypeDescriptionidBIGINTUnique sequential log record ID.database_nameTEXTName of the database hosting the table.schema_nameTEXTSchema namespace (public, app, sales).object_nameTEXTFully qualified table name (schema.table).object_typeTEXTRelation type (table, foreign table).object_oidOIDPostgreSQL internal catalog identifier (pg_class.oid).creation_timeTIMESTAMPTZInferred or exact table creation timestamp.recorded_timeTIMESTAMPTZTimestamp when this row was written to the audit log.detection_methodTEXTTechnical method used to determine the timestamp.Understanding detection_methodBecause PostgreSQL does not natively track table birth dates, pg_creation_tracker labels how each timestamp was obtained:MethodAccuracyExplanationEVENT_TRIGGER100% ExactCreated after extension installation. Captured live via DDL Event Trigger at statement start.COMMIT_TIMESTAMP100% ExactPre-existing table recovered from catalog commit logs via pg_xact_commit_timestamp(xmin).FILESYSTEM_UNMODIFIEDHighPre-existing table whose physical file was never rewritten (relfilenode = oid). Sourced from relation file creation time on disk.REWRITTEN_STORAGE_ESTIMATEApproximatePre-existing table rewritten by VACUUM FULL, TRUNCATE, or ALTER TABLE. Shows the date of the rewrite since the original file was replaced.PARTITION_EARLIEST_CHILD_ESTIMATEHighPartition root tables (relkind = 'p') don't have files on disk; inferred from its earliest child partition file.FILESYSTEM_DIRECTORY_METADATAHighDatabase creation date extracted from the filesystem directory under base/ or pg_tblspc/.UninstallationTo remove tracking cleanly from a database:SQLDROP EXTENSION pg_creation_tracker CASCADE;















