EXTENSION = pgl_ddl_deploy
DATA = pgl_ddl_deploy--1.0.sql
MODULES = pgl_ddl_deploy 

REGRESS := 01_create_ext 02_setup 03_add_configs 04_deploy \
           05_allowed 06_multi 07_edges 08_ignored \
           09_unsupported 10_no_create_user 11_override \
           12_sql_command_tags 13_transaction 14_dep_updates \
           15_new_set_behavior 16_multi_set_tags \
           17_include_only_repset_tables 18_sub_retries \
           99_cleanup
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS) 
