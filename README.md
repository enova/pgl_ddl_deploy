# Pglogical DDL Deployment (pgl_ddl_deploy)

Transparent DDL replication for Postgres 9.5+

[Overview](#overview)
- [High Level Description](#high_level)
- [Features](#features)
- [A Full Example](#full_example)
- [Installation](#installation)

[Setup and Deployment](#setup)
- [Configuration](#config)
- [Permissions](#permissions)
- [Deployment](#deployment)
- [Monitoring and Administration](#monitoring)

[Limitations and Restrictions](#limitations)
- [DDL involving multiple tables](#multi_tables)
- [Unsupported Commands](#unsupported)
- [Multi-Statement Client SQL Limitations](#multi_statement)

[Resolving DDL Replication Issues](#resolve)
- [Resolving Failed DDL on Subscribers](#resolve_failed)
- [Resolving Unhandled DDL](#resolve_unhandled)

[For Developers](#devs)
- [Help Wanted Features](#help_wanted)
- [Regression testing](#regression)

# <a name="overview"></a>Overview

Read the Release Summary:
https://innovation.enova.com/pursuing-postgres-ddl-replication/

## <a name="high_level"></a>High Level Description

With any current logical replication technology for Postgres, we normally have
excellent ways to replicate DML events (`INSERT`, `UPDATE`, `DELETE`), but are
left to figure out propagating DDL changes on our own.  That is, when we create
new tables, alter tables, and the like, we have to manage this separately in our
application deployment process in order to make those same changes on logical
replicas, and add such tables to replication.

As of Postgres 10.0, there is no native way to do "transparent DDL replication"
to other Postgres clusters alongside any logical replication technology, built
on standard Postgres.

This project is an attempt to do just that.  The framework is built on the
following concepts:
- Event triggers always fire on DDL events, and thus give us immediate access to
  what we want 
- Event triggers gives us access (from 9.5+) to what objects are being altered
- We can see what SQL the client is executing within an event trigger
- We can validate and choose to propagate that SQL statement to subscribers
- We can add new tables to replication at the point of creation, prior to any
  DML execution

In many environments, this may cover most if not all DDL statements that are
executed in an application environment.  We know this doesn't cover 100% of edge
cases, but we believe the functionality and robustness is significant enough to
add great value in many Postgres environments.  It will work especially well in
these two use cases:
 - When you want to replicate all user tables
 - When you want to replicate only a subset of tables in a schema that will not
   have any foreign key dependencies to other schemas

We also think it's possible to expand this concept by further leveraging the
Postgres parser.  There is much detail below on what the Limitations and
Restrictions are of this framework.

**NOTE**: The concept implemented here could be extended with any replication
framework that can propagate SQL to subscribers, i.e. skytools and Postgres'
built-in logical replication starting at 10.0.  The reason this has not already
been done is because of time constraints, and because there are a lot of
specifics related to each replication technology. We would welcome a project to
extend this to work with any replication technology.

## <a name="features"></a>Features

- Any DDL SQL statement can be propagated directly to subscribers without your
  developers needing to overhaul their migration process or know the intricacies
of replication.

- Tables will also be automatically added to replication upon creation.

- Filtering by schema (regular expression) is supported.  This allows you to
  selectively replicate only certain schemas within a replication set.
  
- Filtering by a specific set of tables is supported, which is most useful to
  replicate a small set of tables and maintain things like columns added/dropped

- There is an option to deploy in a lock-safe way on subscribers.  Note that
  this means replication will lag until all blockers finish running or are
terminated.

- There is an option to fail certain events on the subscriber to be retried later.
  This is useful for example if you are replicating VIEW DDL but do not want that
  to block replication on failure.

- In some edge cases, alerting can be built around provided logging for the DBA
  to then handle possible manual deployments

## <a name="full_example"></a>A Full Example

Since we always look for documentation by example, we show this first.  Assuming
pglogical is already setup, and given these replication sets:
- `default` - replicate every event
- `insert_update` - replicate only inserts and updates

Provider:
```sql
CREATE EXTENSION pgl_ddl_deploy;

--Setup permissions
SELECT pgl_ddl_deploy.add_role(oid) FROM pg_roles WHERE rolname = 'app_owner';

--Setup configs
INSERT INTO pgl_ddl_deploy.set_configs
(set_name,
include_schema_regex,
lock_safe_deployment,
allow_multi_statements)
VALUES ('default',
  '.*',
  true,
  true),
  ('insert_update',
  '.*happy.*',
  true,
  true);
```

Subscribers (run on both `default` and `insert_update` subscribers):
```sql
CREATE EXTENSION pgl_ddl_deploy;

--Setup permissions for the same role on subscriber to have DDL permissions 
CREATE ROLE app_owner WITH NOLOGIN;
SELECT pgl_ddl_deploy.add_role(oid) FROM pg_roles WHERE rolname = 'app_owner';

--Be sure that on the subscriber, app_owner role has the following perms:
GRANT CREATE ON DATABASE :DBNAME TO app_owner;

--If schemas already exist on subscriber that you want the app_owner
--role to be able to modify with any DDL, then you must do this: 
ALTER TABLE foo OWNER TO app_owner; --...etc
```

Here is a way to fix the subscriber table owner based on the tables already in
replication on provider for the same replication set and ddl configuration you
just setup on provider (shell command):
```sh
PGSERVICE=provider_cluster psql provider_db << EOM | PGSERVICE=subscriber_cluster psql subscriber_db
COPY
(
SELECT 'ALTER TABLE '||quote_ident(n.nspname)||'.'||quote_ident(c.relname)||' OWNER TO app_owner;'
FROM pglogical.replication_set rs
INNER JOIN pgl_ddl_deploy.set_configs sc
  ON sc.set_name = rs.set_name
INNER JOIN pgl_ddl_deploy.rep_set_table_wrapper rsr
  ON rsr.set_id = rs.set_id
INNER JOIN pg_class c ON c.oid = rsr.set_reloid
INNER JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE rs.set_name = 'insert_update'
  AND n.nspname ~* sc.include_schema_regex
  AND n.nspname !~* pgl_ddl_deploy.exclude_regex()
)
TO STDOUT;
EOM
```

Provider:
```sql
--Deploy DDL replication
SELECT pgl_ddl_deploy.deploy(set_name)
FROM pgl_ddl_deploy.set_configs;

--App deployment role
SET ROLE app_owner;

--Let's make some data!
CREATE TABLE foo(id serial primary key);
ALTER TABLE foo ADD COLUMN bla INT;
INSERT INTO foo (bla) VALUES (1),(2),(3);

CREATE SCHEMA happy;
CREATE TABLE happy.foo(id serial primary key);
ALTER TABLE happy.foo ADD COLUMN bla INT;
INSERT INTO happy.foo (bla) VALUES (1),(2),(3);
DELETE FROM happy.foo WHERE bla = 3;
```

Subscriber to `default`:
```
SELECT * FROM foo;
 id | bla
----+-----
  1 | 1
  2 | 2
  3 | 3
(3 rows)

SELECT * FROM happy.foo;
 id | bla
----+-----
  1 | 1
  2 | 2
(3 rows)
```

Note that both tables are replicated based on configuration, as are all events
(inserts, updates, and deletes).

Subscriber to `insert_update`:
```
SELECT * FROM foo;
ERROR:  relation "foo" does not exist
LINE 1: SELECT * FROM foo;

SELECT * FROM happy.foo;
 id | bla
----+-----
  1 | 1
  2 | 2
  3 | 3
(3 rows)
```

Note that the `foo` table (in `public` schema) was not replicated.
Also, because we are not replicating deletes here, `happy.foo` still has all
data.

## <a name="installation"></a>Installation

The functionality of this requires postgres version 9.5+ and a working install
of pglogical.  Packages will be available soon.  To build from source:
```
make
make install
make installcheck # run regression suite
```

See the notes below on requirements to run the regression suite.

This extension requires pglogical to be installed before you can create the
extension in any database. Then the extension can be deployed as any postgres
extension:
```sql
CREATE EXTENSION pgl_ddl_deploy;
```

**This extension needs to be installed on provider and all subscribers.**

**NOTE**: If you upgrade pglogical from version 1.* to 2.* while pgl_ddl_deploy
is installed, you will need to re-run function
`pgl_ddl_deploy.dependency_update()` to update pglogical-specific dependencies.
If you indeed were to upgrade and do nothing, you will likely start to see
`WARNING` level logs indicating a problem.  DDL statements should not fail
because of the way we are allowing exceptions in this deployment framework to
proceed with only a `WARNING` level log.

# <a name="setup"></a>Setup and Deployment 

## <a name="config"></a>Configuration

DDL replication is configured on a per-replication set basis, in terms of
`pglogical.replication_set`.

Add rows to `pgl_ddl_deploy.set_configs` in order to configure (but not yet
deploy) DDL replication for a particular replication set.  For example:
```sql
--Only some options are shown.  See below for all options
INSERT INTO pgl_ddl_deploy.set_configs
(set_name,
include_schema_regex,
lock_safe_deployment,
allow_multi_statements)
VALUES ('default',
  '.*',
  true,
  true);
```

The relevant settings:
- `set_name`: pglogical replication_set name
- `include_schema_regex`: a regular expression for which schemas to include in
  DDL replication.  This can be used to auto-add new tables to replication.  This
  option is incompatible with `include_only_repset_tables`.
- `lock_safe_deployment`: if true, DDL will execute in a low `lock_timeout` loop
  on subscriber
- `allow_multi_statements`: if true, multiple SQL statements sent by client can
  be propagated under certain conditions.  See below for more details on caveats
and edge cases.  If false, only a single SQL statement (technically speaking - a
SQL statement with a single node `parsetree`) will be eligible for propagation.
- `include_only_repset_tables`: if true, only tables that are in replication will
  be maintained by DDL replication.  Thus only `ALTER TABLE`
  statements are permitted here.  This option is incompatible with
  `include_schema_regex`
- `queue_subscriber_failures`: if true, DDL will be allowed to fail on subscriber
  without breaking replication, and queued for retry using function
  `pgl_ddl_deploy.retry_all_subscriber_logs()`.  This is useful for example if you
  are replicating `VIEW` DDL but do not want failures to block data replication. It
  is **NOT** recommendeded that you use this with any `TABLE` replication, since those
  events are likely to break data replication.

There is already a pattern of schemas excluded always that you need not worry
about. You can view them in this function:
```sql
SELECT pgl_ddl_deploy.exclude_regex();
```

You can use this query to check what your current configs will pull in
for schemas:
```sql
SELECT sc.set_name, n.nspname
FROM pg_namespace n
INNER JOIN pgl_ddl_deploy.set_configs sc
  ON nspname !~* pgl_ddl_deploy.exclude_regex()
  AND n.nspname ~* sc.include_schema_regex
ORDER BY sc.set_name, n.nspname;
```

You can use this query to test a new regex for what existing schemas it
matches:
```sql
SELECT n.nspname
FROM pg_namespace n
WHERE nspname !~* pgl_ddl_deploy.exclude_regex()
  AND n.nspname ~* 'test'
ORDER BY n.nspname;
```

There are no stored procedures to insert/update `set_configs`, which we don't
think would add much value at this point.  There is a check constraint in place
to ensure the regex is valid.

## <a name="permissions"></a>Permissions

It is important to consider which role will be allowed to run DDL in a given
provider.  As it stands, this role will need to exist on the subscriber as well,
because this same role will be used to try to deploy on the subscriber.
pgl_ddl_deploy provides a function to provide permissions needed for a given
role to use DDL deployment.  This needs to run provider and all subscribers:
```sql
SELECT pgl_ddl_deploy.add_role(oid)
FROM pg_roles
WHERE rolname IN('app_owner_role');
```

## <a name="deployment"></a>Deployment of Automatic DDL Replication

To **deploy** (meaning activate) DDL replication for a given replication set,
run:
```sql
--Deploy any set_configs with given set_name:
SELECT pgl_ddl_deploy.deploy(set_name);

--Deploy only a single set_config_id:
SELECT pgl_ddl_deploy.deploy(set_config_id);
```
- From this point on, the event triggers are live and will fire on the following
  events (by default, unless you have customized `create_tags` or `drop_tags`):
```
   command_tag
-----------------
 ALTER FUNCTION
 ALTER SEQUENCE
 ALTER TABLE
 ALTER TYPE
 ALTER VIEW
 CREATE FUNCTION
 CREATE SCHEMA
 CREATE SEQUENCE
 CREATE TABLE
 CREATE TABLE AS
 CREATE TYPE
 CREATE VIEW
 DROP FUNCTION
 DROP SCHEMA
 DROP SEQUENCE
 DROP TABLE
 DROP TYPE
 DROP VIEW
 SELECT INTO
```

- Not all of these events are handled in the same way - see Limitations and
  Restrictions below
- Note that if, based on your configuration, you have tables that *should* be
  added to replication already, but are not, you will not be allowed to deploy.
This is because DDL replication should only be expected to automatically add
*new* tables to replication. To override this, add the tables to replication
manually and sync as necessary.

DDL replication can be disabled/enabled (this will disable/enable event
triggers):
```sql
--By set_name
SELECT pgl_ddl_deploy.disable(set_name);
SELECT pgl_ddl_deploy.enable(set_name);

--By set_config_id
SELECT pgl_ddl_deploy.disable(set_name);
SELECT pgl_ddl_deploy.enable(set_name);
```

If you want to **change** the configuration in `set_configs`, you can re-deploy
by again running `pgl_ddl_deploy.deploy` on the given `set_name`.  There is
currently no enforcement/warning if you have changed configuration but not
deployed, but should be easy to add such a feature.

Note that you are able to override the event triggers completely, for example,
if you are an administrator who wants to run DDL and you know you don't want
that propagated to subscribers. You can do this with `SESSION_REPLICATION_ROLE`,
i.e.:

```sql
SET SESSION_REPLICATION_ROLE TO REPLICA;

--I don't care to send this to subscribers
ALTER TABLE foo SET (autovacuum_vacuum_threshold = 1000);

RESET SESSION_REPLICATION_ROLE;
```

## <a name="monitoring"></a>Monitoring and Administration

This framework will log all DDL changes that attempt to be propagated.  It is
also generous in allowing DDL replication procedures to fail in order not to
prevent application deployments of DDL. An exception will never be allowed to
block a DDL statement.  The most that will happen is log_level `WARNING` will be
raised.  This feature is based on the assumption that we do not want replication
issues to ever block client-facing application functionality.

Several tables are setup to manage DDL replication and log exceptions, in
addition to server log warnings raised at `WARNING` level in case of issues:

- `events` - Logs replicated DDL events on the provider
- `subscriber_logs` - Logs replicated DDL events executed on subscribers
- `commands` - Logs detailed output from `pg_event_trigger_ddl_commands()` and
  `pg_event_trigger_dropped_objects()`
- `unhandled` - Any DDL that is captured but cannot be handled by this framework
  (see details below) is logged here.
- `exceptions` - Any unexpected exception raise by the event trigger functions are logged here

There are `resolved` fields on the `unhandled` and `exceptions` tables that can
be marked so that monitoring will show only new problems based on this table by
using functions:
- `pgl_ddl_deploy.resolve_unhandled(unhandled_id INT, notes TEXT = NULL)`
- `pgl_ddl_deploy.resolve_exception(exception_id INT, notes TEXT = NULL)`

# <a name="limitations"></a>Limitations and Restrictions

## <a name="multi_tables"></a>DDL involving multiple tables

A single DDL SQL statement which alters tables both replicated and
non-replicated cannot be supported.  For example, if I have
`include_schema_regex` which includes only the regex `'^replicated.*'`, this is
unsupported:
```sql
DROP TABLE replicated.foo, notreplicated.bar;
```

Likewise, the following can be problematic if you are using filtered replication:
```sql
ALTER TABLE replicated.foo ADD COLUMN foo_id INT REFERENCES unreplicated.foo (id);
```

Depending on your environment, such cases may be very rare, or possibly common.
For example, such edge cases are far less likely when you want to do 1:1
replication of just about all tables in your application database.  Also, if you
are not likely to have relationships between schemas you both are and are not
replicating, then edge cases will be unlikely.  As mentioned above, this
framework will work best with these two use cases:
 - When you want to replicate all user tables
 - When you want to replicate only a subset of tables in a schema that will not
   have any foreign key dependencies to other schemas

In this case, the DDL statement could fail on the subscriber.  To resolve this,
see [Resolving Failed DDL on Subscribers](#resolving_failed).

## <a name="unsupported"></a>Unsupported Commands

`CREATE TABLE AS` and `SELECT INTO` are not supported to replicate DDL due to
limitations on transactional consistency.  That is, if a table is created from a
set of data on the provider, to run the same SQL on the subscriber will in no
way guarantee consistent data.  For example:
```sql
CREATE TABLE foo AS
SELECT field_1, field_2, now() AS refreshed_at
FROM table_1;
```

Not only is it possible that `table_1` doesn't even exist on the subscriber,
even if it does it may not be fully up to date with the provider, in which case
the data created in the table on the subscriber would not match.  Worse, is that
the `now()` function is basically guaranteed to be different on the subscriber.

It is recommended instead that the DDL statement creating the table and
the DML inserting into the table are separated.  Continuing the above
example:
```sql
CREATE TABLE foo (field_1 INT PRIMARY KEY, field_2 TEXT, refreshed_at TIMESTAMPTZ);
INSERT INTO foo (field_1, field_2, refreshed_at)
SELECT field_1, field_2, now() AS refreshed_at
FROM table_1;
```

The above is completely supported by this framework, bearing in mind
some of the edge cases with [multi-statements](#multi_statement).  The
`CREATE TABLE` will automatically be replicated by this framework, and
the table will be added to replication since it has a primary key.  Then
the `INSERT` will be replicated by normal pglogical replication.

**NOTE** that temp tables are not affected by this limitation, since temp objects are
always excluded from DDL replication anyway.

To resolve these, see [Resolving Unhandled DDL](#resolve_unhandled).

## <a name="multi_statement"></a>Multi-Statement Client SQL Limitations

It is important to understand that limitations on multi-statement client SQL has
nothing to do with executing multiple SQL statements at once, or in one
transaction.  Of course, it is assumed that will often or even usually be the
case, and this framework can handle that just fine.

The complexities and limitations come when the *client* sends all SQL statements
as one single string to Postgres.  Assume the following SQL statements:

```sql
CREATE TABLE foo (id serial primary key, bla text);
INSERT INTO foo (bla) VALUES ('hello world');
```

If this was in a file that I called via psql, it would run as two separate SQL
command strings.

However, if in python or ruby's ActiveRecord I create a single string as above
and execute it, then it would be sent to Postgres as 1 single SQL command
string.  In such a case, this framework is aware that a multi-statement is
being executed by using Postgres' parser to get the command tags of the full
SQL statement.  You have a little freedom here with the
`allow_multi_statements` option:
- If `false`, pgl_ddl_deploy will *only* auto-replicate a client SQL statement
  that contains 1 command tag that matches the event trigger command tag.
That's really safe, but it means you may have a lot more unhandled deployments.
- If `true`, pgl_ddl_deploy will *only* auto-replicate DDL that contains
  **safe** command tags to propagate.  For example, mixed DDL and DML is
forbidden, because executing such a statement would in effect double-execute
DML on both provider and subscriber.  However, if you have a `CREATE TABLE` and
`ALTER TABLE` in one command, assuming the table should be included in
replication based on your configuration, then such a statement will be sent to
subscribers.  But of course, we can't guarantee that all DDL statements in this
command are on the same table - so there could be edge cases.

In any case that a SQL statement cannot be automatically run on the subscriber
based on these analyses, instead it will be logged as a `WARNING` and put into
the `unhandled` table for manual processing.

To resolve these, see [Resolving Unhandled DDL](#resolve_unhandled).

The regression suite in the `sql` folder has examples of several of these cases.

Thus, limitations on multi-statement SQL is largely based on how your client
sends its messages in SQL to Postgres, and likewise how your developers tend to
write SQL.  The good thing about this is that it ought to be much easier to
train developers to logically separate SQL in their migrations, as opposed to
far more work we need to do when we don't have any kind of transparent DDL
replication.

These limitations obviously have to be weighed against the cost of not using a
framework like this at all in your environment.

The `unhandled` table and `WARNING` logs are designed to be leveraged with
monitoring to create alerting around when manual intervention is required for
DDL changes.

# <a name="resolve"></a>Resolving DDL Replication Issues

## <a name="resolve_failed"></a>Resolving Failed DDL on Subscribers

In some cases, you may propagate DDL that fails on the subscriber, and
replication will break, unless you have enabled `queue_subscriber_failures`.
You will then need to:
- Manually deploy with the same SQL statement modified so that it excludes the
  failing portion.  For the example above of both adding a column and adding a
foreign key, assuming we don't have that `unreplicated` table, then you would
run:
```sql
ALTER TABLE replicated.foo ADD COLUMN foo_id INT;
```
- Consume the change in affected replication slot using
  `pg_logical_slot_get_changes` **up to specific LSN** of the transaction which
included the DDL statement to get replication working again.
- Re-enable replication for affected subscriber(s)

If you are using `queue_subscriber_failures`, any DDL failures for your given
configuration will be logged as failed in `pgl_ddl_deploy.subscriber_logs`.
You can resolve issues, and attempt to re-deploy by using functions:
```sql
--Retry all failed, in transactional order
SELECT pgl_ddl_deploy.retry_all_subscriber_logs();

--Retry only a single failed log
SELECT pgl_ddl_deploy.retry_subscriber_log(subscriber_log_id);
```

## <a name="resolve_unhandled"></a>Resolving Unhandled DDL

At present, an unhandled DDL deployment **may not break replication** by itself.
If the DDL statement that could not be deployed doesn't actually affect any data
being replicated (for example, a brand new table is added), then replication
will continue.  However, the situation should be resolved ASAP because it is
assumed that whatever table(s) that were involved in the DDL **should** be
propagated to subscribers.  It is also possible that replication will break
immediately.  For example, if a column is added to the table, and data is
replicating, it will fail immediately because of a column mismatch.  In such
cases you will need to:
- Manually deploy the unhandled SQL statement modified so that it excludes the
  unhandled portion.  For the example of a multi-statement SQL above, you would
need to exclude the `INSERT` portion of the SQL and run:
```sql
CREATE TABLE foo (id serial primary key, bla text);
```
- If a new table is involved, in this case you also will need to manually add
  the table to replication using `pglogical.replication_set_add_table`
- If a new table is involved, you may need to resynchronize the table if data
  has been replicating for it
- If a new table is NOT involved (for example `ALTER TABLE ADD COLUMN`), then
  replication will simply continue where it broke
- Re-enable replication for affected subscriber(s)
- Mark your unhandled records as resolved using function:
```sql
SELECT pgl_ddl_deploy.resolve_unhandled(unhandled_id INT, notes TEXT = NULL);
```

To be more conservative, we may want a feature that forces replication to break
if there is an unhandled deployment, for example, by sending an exception
through `replicate_ddl_command`.  But such a feature may cause additional and
unnecessary administration overhead, since it is likely the strictness of
replication will cause the system to break when it should. 

# <a name="devs"></a>For Developers

## <a name="help_wanted"></a>Help Wanted Features
We are currently using the parser only to get the list of command tags.  One
big advantage to this is that it isn't going to be difficult to maintain as
Postgres develops.  One disadvantage is that it tells us nothing about the
actual objects being modified, nor the type of modification.

We believe it is feasible to use the parser to actually only process the parts
of a multi-statement SQL command that we want to, but this far more ambitious,
and would be more work to maintain.  We would need to leverage the different
structures of each DDL command's `parsetree` to determine if the table is in a
schema we care to replicate.  Then, we would need to use the parser's lex code
to take out the piece(s) we want.

Theoretically speaking, don't we have all that we need in the SQL statement +
the parser to programatically use only what we want and send it to subscribers?
I think we do, but lots of work would be required, and we would welcome those
with more comfort in the parser code to help if interested.

## <a name="sql files"></a>SQL files
To build the higher version SQL files (i.e. 1.1) from the lower versions +
the upgrade patch SQL files, run `pgl_ddl_deploy-sql-maker.sh`.

## <a name="regression"></a>Regression testing
You can run the regression suite, which must be on a server that has pglogical
packages available, and a cluster that is configured to allow creating the
pglogical extension (i.e. adding it to `shared_preload_libraries`).  Note that
the regression suite does not do any cross-server replication testing, but it
does cover a wide variety of replication cases and the core of what is needed
to verify DDL replication.

As with any Postgres extension:
```
make install
make installcheck

# There is support for testing both 1.1 and the upgraded path from 1.0 to 1.1
FROMVERSION=1.0 make installcheck   # Test from 1.0 upgrade to 1.1
FROMVERSION=1.1 make installcheck
```
