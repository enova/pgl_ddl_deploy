#include "postgres.h"
#include "fmgr.h"
#include "catalog/pg_type.h"
#include "tcop/utility.h"
#include "utils/builtins.h"
#include "parser/parser.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(sql_command_tags);

/*
 * Return a text array of the command tags in SQL command
 */
Datum
sql_command_tags(PG_FUNCTION_ARGS)
{
    text            *sql_t  = PG_GETARG_TEXT_P(0);
    char            *sql;
    List            *parsetree_list; 
    ListCell        *parsetree_item;
    const char      *commandTag;
    ArrayBuildState *astate = NULL;
    
    /*
     * Get the SQL parsetree
     */
    sql = text_to_cstring(sql_t);
    parsetree_list = pg_parse_query(sql);

    /*
     * Iterate through each parsetree_item to get CommandTag
     */
    foreach(parsetree_item, parsetree_list)
    {   
        Node    *parsetree = (Node *) lfirst(parsetree_item);
        commandTag         = CreateCommandTag(parsetree);
        astate             = accumArrayResult(astate, CStringGetTextDatum(commandTag),
                             false, TEXTOID, CurrentMemoryContext);
    }
    if (astate == NULL)
                elog(ERROR, "Invalid sql command");
    PG_RETURN_ARRAYTYPE_P(makeArrayResult(astate, CurrentMemoryContext));
}

