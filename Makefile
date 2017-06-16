EXTENSION = pgl_ddl_deploy
DATA = pgl_ddl_deploy--0.1.sql
DOCS = README.pgl_ddl_deploy.md
MODULES = pgl_ddl_deploy 

REGRESS := 01_create_ext 02_setup 03_add_configs 04_deploy 05_allowed 06_multi 07_edges 99_cleanup
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS) 
