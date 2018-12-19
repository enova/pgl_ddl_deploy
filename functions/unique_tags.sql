CREATE OR REPLACE FUNCTION pgl_ddl_deploy.unique_tags()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_output TEXT;
BEGIN
    WITH dupes AS (
    SELECT set_name,
        CASE
            WHEN include_only_repset_tables THEN 'include_only_repset_tables'
            WHEN include_everything AND NOT ddl_only_replication THEN 'include_everything'
            WHEN include_schema_regex IS NOT NULL AND NOT ddl_only_replication THEN 'include_schema_regex'
            WHEN ddl_only_replication THEN
                CASE
                    WHEN include_everything THEN 'ddl_only_include_everything'
                    WHEN include_schema_regex IS NOT NULL THEN 'ddl_only_include_schema_regex'
                END
        END AS category,
    unnest(array_cat(create_tags, drop_tags)) AS command_tag
    FROM pgl_ddl_deploy.set_configs
    GROUP BY 1, 2, 3
    HAVING COUNT(1) > 1)

    , aggregate_dupe_tags AS (
    SELECT set_name, category, string_agg(command_tag, ', ' ORDER BY command_tag) AS command_tags
    FROM dupes
    GROUP BY 1, 2
    )

    SELECT string_agg(format('%s: %s: %s', set_name, category, command_tags), ', ') AS output
    INTO v_output
    FROM aggregate_dupe_tags;

    IF v_output IS NOT NULL THEN
        RAISE EXCEPTION '%', format('You have overlapping configuration types and command tags which is not permitted: %s', v_output);
    END IF;
    RETURN NULL;
END;
$function$
;
