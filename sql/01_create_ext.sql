-- Allow running regression suite with upgrade paths
\set v `echo ${FROMVERSION:-2.1}`
SET client_min_messages = warning;
CREATE EXTENSION pglogical;
CREATE EXTENSION pgl_ddl_deploy VERSION :'v';
