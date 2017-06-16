# pgl_ddl_deploy
Automated DDL deployment using Pglogical

## High Level Description
As of Postgres 10.0, there is no deeply native way to propagate DDL to other DB clusters.
Normally this is a puzzle with logical replication, where we have excellent DML replication
but are left to figure out DDL propagation in the application deployment process.

This project is an attempt to create a very robust way to do this using the client's SQL
command combined with event trigger functionality starting with postgres 9.5.  Although it
does not cover 100% of cases, we believe the functionality and robustness is significant
enough to add great value in many Postgres environments.

NOTE: The concept implemented here could be extended with any replication framework that can
propagate SQL to subscribers, i.e. skytools and Postgres' built-in logical replication
starting at 10.0.  The reason this has not already been done is because of time constraints,
and because there are a lot of specifics related to each replication technology.
I would welcome a project to extend this to work with any replication technology.

## Features
- Any SQL statement can be propagated directly to subscribers without any modification to
deployment processes.  Event triggers will fire on relevant DDL statements and propagate to
subscribers, based on your configuration.

- Tables will also be automatically added to replication upon creation.

- Filtering by schema (regular expression) is supported.  This allows you to selectively
replicate only certain schemas within a replication set.

- There is an option to deploy in a lock-safe way on subscribers.  Note that this means
replication will lag until all blockers finish running or are terminated.

## A Full Example
Since we always look for documentation by example, we show this first.  Assuming pglogical
is already setup, and given these replication sets:
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

--Setup permissions (see below for why we need this role on subscriber also)
SELECT pgl_ddl_deploy.add_role(oid) FROM pg_roles WHERE rolname = 'app_owner';
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
ALTER TABLE foo ADD COLUMN bla TEXT;
INSERT INTO foo (bla) VALUES (1),(2),(3);

CREATE SCHEMA happy;
CREATE TABLE happy.foo(id serial primary key);
ALTER TABLE happy.foo ADD COLUMN bla TEXT;
INSERT INTO happy.foo (bla) VALUES (1),(2),(3);
```

Subscriber to `default`:
```
postgres=# SELECT * FROM foo;
 id | bla
----+-----
  1 | 1
  2 | 2
  3 | 3
(3 rows)

postgres=# SELECT * FROM happy.foo;
 id | bla
----+-----
  1 | 1
  2 | 2
  3 | 3
(3 rows)
```

Subscriber to `insert_update`:
```
postgres=# SELECT * FROM foo;
ERROR:  relation "foo" does not exist
LINE 1: SELECT * FROM foo;

postgres=# SELECT * FROM happy.foo;
 id | bla
----+-----
  1 | 1
  2 | 2
  3 | 3
(3 rows)
```

## Installation
The functionality of this requires postgres version 9.5+.  Packages are available.

This extension requires pglogical to be installed before you can create the extension in
any database. Then the extension can be deployed as any postgres extension:
```sql
CREATE EXTENSION pgl_ddl_deploy;
```

**This extension needs to be installed on provider and all subscribers.**

# Setting up DDL replication

## Configuration
DDL replication is configured on a per-replication set basis, in terms of `pglogical.replication_set`.

Add rows to `pgl_ddl_deploy.set_configs` in order to configure (but not yet deploy) DDL replication
for a particular replication set.  The relevant settings:
- `set_name`: pglogical replication_set name
- `include_schema_regex`: a regular expression for which schemas to include in DDL replication
- `lock_safe_deployment`: if true, DDL will execute in a low `lock_timeout` loop on subscriber
- `allow_multi_statements`: if true, multiple SQL statements sent by client can be propagated under
certain conditions.  See below for more details on caveats and edge cases.  If false, only a
single SQL statement (technically speaking - a SQL statement with a single node `parsetree`)
will be eligible for propagation.

There is already a pattern of schemas excluded always that you need not worry about. You
can view them in this function:
```sql
SELECT pgl_ddl_deploy.exclude_regex();
```

There is no stored procedure to insert/update `set_configs`, which we don't think would add much value
at this point.  There is a check constraint in place to ensure the regex is valid.

## Permissions
It is important to consider which role will be allowed to run DDL in a given provider.  As it stands,
this role will need to exist on the subscriber as well, because this same role will be used to try
to deploy on the subscriber.  pgl_ddl_deploy provides a function to provide permissions needed for
a given role to use DDL deployment.  This needs to run provider and all subscribers:
```sql
SELECT pgl_ddl_deploy.add_role(oid)
FROM pg_roles
WHERE rolname IN('app_owner_role');
```

To **deploy** (meaning activate) DDL replication for a given replication set, run:
```sql
SELECT pgl_ddl_deploy.deploy(set_name);
```
- Note that if, based on your configuration, you have tables that *should* be added to
replication already, but are not, you will not be allowed to deploy.  This is because
DDL replication should only be expected to automatically add *new* tables to replication.
To override this, add the tables to replication manually and sync as necessary.

DDL replication can be disabled/enabled (this will disable/enable event triggers):
```sql
SELECT pgl_ddl_deploy.disable(set_name);
SELECT pgl_ddl_deploy.enable(set_name);
```

# Administration and Monitoring
This framework will log all DDL changes that attempt to be propagated.  It is also generous in
allowing DDL replication procedures to fail in order not to prevent application deployments of DDL.
An exception will never be allowed to block a DDL statement.  The most that will happen is
log_level `WARNING` will be raised.  This feature is based on the assumption that we do not want
replication issues to ever block client-facing application functionality.

Several tables are setup to manage DDL replication and log exceptions, in addition to server log
warnings raised at `WARNING` level in case of issues:

- `events` - Logs replicated DDL events on the provider
- `subscriber_logs` - Logs replicated DDL events executed on subscribers
- `commands` - Logs detailed output from `pg_event_trigger_ddl_commands()` and `pg_event_trigger_dropped_objects()`
- `unhandled` - Any DDL that is captured but cannot be handled by this framework (see details below) is logged here
- `exceptions` - Any unexpected exception raise by the event trigger functions are logged here

## Limitations and Restrictions
1. A single DDL SQL statement which alters tables both replicated and non-replicated cannot
be supported.  For example, if I have `include_schema_regex` which includes only
'^replicated.*', this is unsupported:
```sql
DROP TABLE replicated.foo, notreplicated.bar;
```

Likewise, this can be problematic if you are using filtered replication:
```sql
ALTER TABLE replicated.foo ADD COLUMN foo_id REFERENCES unreplicated.foo (id);
```

Depending on your environment, such cases may be very rare, or possibly common.  In any case,
what will happen if such a statement gets propagated is that it will fail on the subscriber,
and you will need to:
- Manually deploy, if necessary.  In the example above, you might need to manually run:
```sql
ALTER TABLE replicated.foo ADD COLUMN foo_id;
```
- Consume the change in affected replication slot using `pg_logical_slot_get_changes` to get
replication working again.
- Re-enable replication for affected subscriber(s)

2. `CREATE TABLE AS` and `SELECT INTO` are not supported to replicate DDL due to limitations on
transactional consistency.  That is, if a table is created from a set of data on the provider,
to run the same SQL on the subscriber will in no way guarantee consistent data.  It is recommendeded
instead that the DDL statement creating the table and the DML inserting into the table are separated.
**NOTE** that temp tables will not be affected by this, since temp objects are always excluded from DDL
replication.


3. If your DDL statement exceeds the length of `track_activity_query_size`, an unhandled exception
will be logged.  It is recommended to run higher settings (10-15k for example) for
`track_activity_query_size` to use this framework effectively.

## Multi-Statement SQL Limitations
There is inherently NO LIMITATION on what kind of SQL can be supported by this framework if a client
sends SQL statements 1 by 1, which is sometimes true but sometimes not.  For example, a psql script
will execute even a long SQL script 1 statement at a time, and so can be supported very well. But
python's psycopg2 will send a single blob of SQL to the client at once.  For example:

```sql
CREATE TABLE foo (id serial primary key, bla text);
INSERT INTO foo (bla) VALUES ('hello world');
```

If this was in a file that I called via psql, it would run fine.  But if I ran in python:
```python
cur.execute(sql)
```
then it would be sent to Postgres as 1 SQL statement.  In such a case, the SQL statement cannot
be automatically run on the subscriber.  Instead, it will be logged as a `WARNING` and put into
the `unhandled` table for manual processing.

Thus, limitations on multi-statement SQL is largely based on how your client sends its messages in SQL to
Postgres, and likewise how your developers tend to write SQL.  The good thing about this is that
pgl_ddl_deploy does a lot of work to figure out if it is getting a multi-statement by using the
built-in parser to get the list of command tags in a SQL statement.  

It is very likely that replication will break in such cases, and you will have to manually intervene.

These limitations obviously have to be weighed against the cost of not using a framework like this
at all.

The `unhandled` table and `WARNING` logs are designed to be leveraged with monitoring to create
alerting around when manual intervention is required for DDL changes.

## Help Wanted Features
We believe it is feasible to use the parser to actually only process the parts of a multi-statement
SQL command that we want to, but this far more ambitious.  We would need to leverage the different
structures of each DDL command's parsetree to determine if the table is in a schema we care to
replicate.  Then, we would need to use the lex code to take out the piece we want. 

# For Developers
## Regression testing
You can run the regression suite, which must be on a server that has pglogical packages
available.  Note that the regression suite does not do any cross-server replication
testing, but it does cover a wide variety of replication cases and the core of what is
needed to verify DDL replication.

As with any extension:
```
make install
make installcheck
```
