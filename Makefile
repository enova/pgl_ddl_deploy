EXTENSION = pgl_ddl_deploy
DATA = pgl_ddl_deploy--0.1.sql
DOCS = README.pgl_ddl_deploy.md

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS) 
