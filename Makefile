EXTENSION = pgl_ddl_deploy
DATA = pgl_ddl_deploy--0.1.sql
MODULES = pgl_ddl_deploy 

REGRESS := 01_create_ext 02_setup 03_add_configs 04_deploy \
           05_allowed 06_multi 07_edges 08_ignored \
           09_unsupported 10_no_create_user 11_override \
           12_sql_command_tags 13_transaction 14_dep_updates \
           99_cleanup
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS) 
