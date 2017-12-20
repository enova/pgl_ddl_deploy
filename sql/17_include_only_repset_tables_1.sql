SET client_min_messages = warning;
SET ROLE test_pgl_ddl_deploy;

--These kinds of repsets will not replicate CREATE events, only ALTER TABLE, so deploy after CREATE
--We assume schema will be copied to subscriber separately
CREATE SCHEMA special;
CREATE TABLE special.foo (id serial primary key, foo text, bar text);
CREATE TABLE special.bar (id serial primary key, super text, man text);
