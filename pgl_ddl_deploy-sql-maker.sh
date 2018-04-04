#!/usr/bin/env bash

set -eu

# 1.1
cat pgl_ddl_deploy--1.0.sql > pgl_ddl_deploy--1.1.sql
cat pgl_ddl_deploy--1.0--1.1.sql >> pgl_ddl_deploy--1.1.sql

# 1.2
cp pgl_ddl_deploy--1.1.sql pgl_ddl_deploy--1.2.sql
cat pgl_ddl_deploy--1.1--1.2.sql >> pgl_ddl_deploy--1.2.sql

# 1.3
cp pgl_ddl_deploy--1.2.sql pgl_ddl_deploy--1.3.sql
cat pgl_ddl_deploy--1.2--1.3.sql >> pgl_ddl_deploy--1.3.sql
