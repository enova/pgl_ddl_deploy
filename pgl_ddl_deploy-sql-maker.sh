#!/usr/bin/env bash

set -eu

last_version=1.3
new_version=1.4
last_version_file=pgl_ddl_deploy--${last_version}.sql
new_version_file=pgl_ddl_deploy--${new_version}.sql
update_file=pgl_ddl_deploy--${last_version}--${new_version}.sql

rm -f $update_file
rm -f $new_version_file

create_update_file_with_header() {
cat << EOM > $update_file
/* $update_file */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgl_ddl_deploy" to load this file. \quit

EOM
}

add_sql_to_file() {
sql=$1
file=$2
echo "$sql" >> $file
}

add_file() {
s=$1
d=$2
(cat "${s}"; echo; echo) >> "$d"
}

create_update_file_with_header

# Add view and function changes
add_file functions/dependency_update.sql $update_file

# Add NEW table schema and extension config changes
add_file schema/1.4.sql $update_file

# Only copy diff and new files after last version, and add the update script
cp $last_version_file $new_version_file
cat $update_file >> $new_version_file
