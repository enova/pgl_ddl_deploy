EXTENSION = pgl_ddl_deploy
DATA = pgl_ddl_deploy--1.0.sql pgl_ddl_deploy--1.0--1.1.sql \
        pgl_ddl_deploy--1.1.sql pgl_ddl_deploy--1.1--1.2.sql \
        pgl_ddl_deploy--1.2.sql pgl_ddl_deploy--1.2--1.3.sql \
        pgl_ddl_deploy--1.3.sql pgl_ddl_deploy--1.3--1.4.sql \
        pgl_ddl_deploy--1.4.sql pgl_ddl_deploy--1.4--1.5.sql \
        pgl_ddl_deploy--1.5.sql pgl_ddl_deploy--1.5--1.6.sql \
        pgl_ddl_deploy--1.6.sql pgl_ddl_deploy--1.6--1.7.sql \
        pgl_ddl_deploy--1.7.sql pgl_ddl_deploy--1.7--2.0.sql \
        pgl_ddl_deploy--2.0.sql pgl_ddl_deploy--2.0--2.1.sql \
        pgl_ddl_deploy--2.1.sql
MODULES = pgl_ddl_deploy ddl_deparse

REGRESS := 01_create_ext 02_setup 03_add_configs 04_deploy 04_deploy_update \
           05_allowed 06_multi 07_edges 08_ignored \
           09_unsupported 10_no_create_user 11_override \
           12_sql_command_tags 13_transaction \
           15_new_set_behavior 16_multi_set_tags \
           17_include_only_repset_tables_1 \
           18_include_only_repset_tables_2 \
           19_include_only_repset_tables_3 \
           20_include_only_repset_tables_4 21_unprivileged_users \
           22_is_deployed 23_1_4_features 24_sub_retries \
           25_1_5_features 26_new_setup \
           27_raise_message 28_1_6_features \
           29_create_ext \
           30_setup \
           31_add_configs \
           32_deploy_update \
           33_allowed \
           34_multi \
           35_edges \
           36_ignored \
           37_unsupported \
           38_no_create_user \
           39_override \
           40_sql_command_tags \
           41_transaction \
           43_new_set_behavior \
           44_multi_set_tags \
           45_include_only_repset_tables_1 \
           46_include_only_repset_tables_2 \
           47_include_only_repset_tables_3 \
           48_include_only_repset_tables_4 \
           49_unprivileged_users \
           50_is_deployed \
           51_1_4_features \
           52_sub_retries \
           53_1_5_features \
           54_new_setup \
           55_raise_message \
           56_1_6_features \
           57_native_features
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Prevent unintentional inheritance of PGSERVICE while running regression suite
# with make installcheck.  We typically use PGSERVICE in our shell environment but
# not for dev. Require instead explicit PGPORT= or PGSERVICE= to do installcheck
unexport PGSERVICE
