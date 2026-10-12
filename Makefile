EXTENSION = pg_creation_tracker
DATA = pg_creation_tracker--1.0.sql
PGFILEDESC = "pg_creation_tracker - Automated database and table creation audit"

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
