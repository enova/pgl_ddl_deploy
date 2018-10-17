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

# Pre-schema changes
add_file schema/1.4.sql $update_file

# Add view and function changes
add_file functions/rep_set_table_wrapper.sql $update_file
add_file functions/deployment_check_wrapper.sql $update_file
add_file functions/deployment_check.sql $update_file
add_file functions/deployment_check_count.sql $update_file
add_file views/event_trigger_schema.sql $update_file
add_file functions/get_altertable_subcmdtypes.sql $update_file
add_file functions/get_command_tag.sql $update_file
add_file functions/get_command_type.sql $update_file
add_file functions/standard_repset_only_tags.sql $update_file
add_file functions/standard_create_tags.sql $update_file
add_file functions/exclude_regex.sql $update_file
add_file functions/common_exclude_alter_table_subcommands.sql $update_file
add_file functions/unique_tags.sql $update_file

# Add NEW table schema and extension config changes
add_file schema/1.4_post.sql $update_file

# Only copy diff and new files after last version, and add the update script
cp $last_version_file $new_version_file
cat $update_file >> $new_version_file
