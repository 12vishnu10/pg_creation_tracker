# pg_track

`pg_track` is an automated PostgreSQL auditing and metadata extension that reliably captures creation timestamps for databases, schemas, tables, and indexes across an entire cluster.

It solves PostgreSQL's default limitation where object creation timestamps are not natively stored in system catalogs (`pg_class`, `pg_database`, `pg_namespace`).

---

## Key Features

* **Cluster-Wide Database Creation Tracking:** Identifies exact creation timestamps for all databases by reading underlying filesystem metadata (`PG_VERSION`) across default and custom tablespaces.
* **Real-Time DDL Audit via Event Triggers:** Captures tables, partitioned tables, foreign tables, schemas, and indexes as soon as they are executed.
* **Historical Backfill Engine:** Evaluates existing pre-extension relations using commit log transactions (`track_commit_timestamp`), partition hierarchies, and relation filenode creation estimates.
* **Clean Namespace Isolation:** All tables, helper functions, and audit views are sequestered under the `track` schema (`track.tables`, `track.schemas`, `track.indexes`, `track.databases`).
* **Cluster Inheritance Ready:** Integrates cleanly with `template1` to automatically enable tracking on all newly provisioned databases.

---

## Architecture & Detection Methods

| Method | Description | Target Scope |
| :--- | :--- | :--- |
| `EVENT_TRIGGER` | Real-time DDL capture via `ddl_command_end` event triggers. | New tables, indexes, and schemas |
| `FILESYSTEM_PG_VERSION_METADATA` | Inspects creation/birth timestamps of `$PGDATA/base/<db_oid>/PG_VERSION` or `pg_tblspc/<spc_oid>/<version>/<db_oid>/PG_VERSION`. | Databases (default & custom tablespaces) |
| `COMMIT_TIMESTAMP` | Retrieved via `pg_xact_commit_timestamp(xmin)` when `track_commit_timestamp = on`. | Existing pre-install objects |
| `PARTITION_EARLIEST_CHILD_ESTIMATE` | Earliest storage creation time derived from constituent child partitions. | Partitioned tables & indexes |
| `FILESYSTEM_UNMODIFIED` | Storage modification time when relfilenode equals object OID. | Pre-existing relations |
| `REWRITTEN_STORAGE_ESTIMATE` | Fallback timestamp estimate for relations rewritten via `VACUUM FULL` / `ALTER TABLE`. | Pre-existing relations |

---

## Installation

### Prerequisites

* PostgreSQL 17
* Optional (for improved backfill accuracy on legacy objects): `track_commit_timestamp = on` in `postgresql.conf`.

### 1. Install via RPM (RHEL / Rocky / AlmaLinux 9/10)

Download and install the pre-built binary package directly from the GitHub releases page:

```bash
sudo dnf install -y https://github.com/12vishnu10/pg_track/releases/download/v1.0.0/pg_track17-1.0-2.el10.noarch.rpm
```

### 2. Build and Install from Source

```bash
git clone https://github.com/12vishnu10/pg_track.git
cd pg_track

# Copy extension files directly into the PostgreSQL shared directory
sudo cp pg_track.control /usr/pgsql-17/share/extension/
sudo cp pg_track--1.0.sql /usr/pgsql-17/share/extension/
```

---

## Enabling the Extension

### In an Existing Database

Connect to your target database and run:

```sql
CREATE EXTENSION pg_track;
```

Upon creation, `pg_track` automatically runs a backfill routine to catalog all existing schemas, tables, and indexes.

---

## Automatic Cluster-Wide Propagation (`template1`)

To ensure that **every future database** created on your cluster automatically includes `pg_track` with zero manual intervention, install the extension into `template1`:

```bash
sudo -u postgres psql -d template1 -c "CREATE EXTENSION IF NOT EXISTS pg_track;"
```

### How It Works

Because PostgreSQL creates new databases by copying `template1` at the storage level:
1. Every subsequent `CREATE DATABASE <name>;` command will inherit the `track` schema, views, and event triggers.
2. The event trigger automatically begins tracking DDL in the new database immediately.

```sql
-- Test propagation
CREATE DATABASE analytics_app;
\c analytics_app

-- Verify the extension is already loaded
\dx pg_track

-- View pre-populated tracking
SELECT * FROM track.tables;
```

---

## Usage and Views Reference

All monitoring views are queried under the `track` schema.

### 1. Database Creation History (`track.databases`)

Lists all databases in the cluster, their storage tablespace, and creation timestamp:

```sql
SELECT database_name, tablespace_name, creation_time, detection_method
FROM track.databases
ORDER BY creation_time DESC;
```

**Example Output:**

```text
 database_name | tablespace_name |         creation_time          |        detection_method        
---------------+-----------------+--------------------------------+--------------------------------
 cmd           | cmd_tbspc       | 2026-10-12 18:37:19.458921+00  | FILESYSTEM_PG_VERSION_METADATA
 timestamp_lab | pg_default      | 2026-10-12 17:09:57.102341+00  | FILESYSTEM_PG_VERSION_METADATA
 postgres      | pg_default      | 2026-09-07 17:31:06.000000+00  | FILESYSTEM_PG_VERSION_METADATA
```

### 2. Table Creation History (`track.tables`)

Shows creation timestamps for regular, partitioned, and foreign tables:

```sql
SELECT schema_name, object_name, creation_time, detection_method
FROM track.tables
ORDER BY creation_time DESC;
```

### 3. Index Creation History (`track.indexes`)

Displays creation timestamps for primary keys, secondary indexes, and partitioned indexes:

```sql
SELECT schema_name, object_name, creation_time, detection_method
FROM track.indexes
ORDER BY creation_time DESC;
```

### 4. Schema Creation History (`track.schemas`)

Tracks user-created schemas:

```sql
SELECT schema_name, creation_time, detection_method
FROM track.schemas
ORDER BY creation_time DESC;
```

### 5. Master Audit Log (`track.objects`)

Inspect the complete audit journal containing raw OIDs, registration timestamps, and object types:

```sql
SELECT 
    id,
    object_type,
    schema_name,
    object_name,
    creation_time,
    recorded_time,
    detection_method
FROM track.objects
ORDER BY id DESC
LIMIT 20;
```

---

## Manual Backfill

If historical objects were imported or restored using tools that bypass standard DDL triggers (e.g., low-level logical restores), you can trigger the backfill engine manually at any time:

```sql
SELECT track.backfill_existing_objects();
```

---

## Verification & Testing

Verify end-to-end event trigger capturing:

```sql
-- Create a schema, table, and index
CREATE SCHEMA test_app;
CREATE TABLE test_app.invoices (id bigint primary key, amount numeric);
CREATE INDEX idx_invoices_amount ON test_app.invoices(amount);

-- Check audit entries
SELECT object_type, object_name, creation_time, detection_method
FROM track.objects
WHERE schema_name = 'test_app';
```

---

## Uninstallation

To remove `pg_track` from a database:

```sql
DROP EXTENSION pg_track CASCADE;
```

To remove the RPM from your operating system:

```bash
sudo dnf remove -y pg_track17
```

---

## License

This project is licensed under the [PostgreSQL License](LICENSE).