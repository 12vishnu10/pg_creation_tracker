# pg_creation_tracker

Automated PostgreSQL database and table creation timestamp tracker.

PostgreSQL system catalogs (`pg_class`, `pg_database`) do not natively maintain an object creation timestamp. `pg_creation_tracker` solves this limitation by providing:
- **Live DDL Audit:** Captures real-time table creation timestamps via native Event Triggers.
- **Forensic Historical Backfill:** Recovers creation timestamps for tables created prior to extension installation using commit logs, partition hierarchies, and storage metadata.
- **Database Creation Auditing:** Tracks creation timestamps for all databases in the cluster across standard and custom tablespaces.
- **Zero External Dependencies:** Pure SQL and PL/pgSQL. No C compiler or development headers required.

---

## Installation

### From Source (PGXS Make)
Ensure `pg_config` is in your `PATH`:
