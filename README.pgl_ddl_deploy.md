# pgl_ddl_deploy
Automated DDL deployment using Pglogical

# Installation
The functionality of this requires postgres version 9.5+.

pgl_ddl_deploy can be build using `make`, and uses the PGXS build framework by default.  Server requires `postgresql-devel` packages in order to build.  Also, the directory containing `pg_config` needs to be in your `$PATH`.

```
cd pgl_ddl_deploy
make
sudo make install
```

This extension requires pglogical to be installed before you can create the extension in any database. Then the extension can be deployed as any postgres extension:
```
SET ROLE postgres;  # Or whatever role you want to own extension
CREATE EXTENSION pgl_ddl_deploy;
```

# Managing DDL replication
DDL replication is configured on a per-replication set basis, in terms of `pglogical.replication_set`.

Add rows to `pgl_ddl_deploy.set_configs` in order to configure (but not yet deploy) DDL replication for a particular replication set.

To **deploy** (meaning activate) DDL replication for a given replication set, run:
```sql
SELECT pgl_ddl_deploy.deploy(set_name);
```

# Administration and Monitoring
This framework will log all DDL changes that attempt to be propagated.  It is also generous in allowing DDL replication procedures to fail in order not to prevent application deployments of DDL.

Several tables are setup to manage this and log exceptions, in addition to server log warnings raised at WARNING level in case of issues:

- `events` - Logs replicated DDL events on the provider
- `subscriber_logs` - Logs replicated DDL events executed on subscribers
- `commands` - Logs detailed output from `pg_event_trigger_ddl_commands()` and `pg_event_trigger_dropped_objects()`
- `unhandled` - Any DDL that is captured but cannot be handled by this framework (see details below) is logged here
- `exceptions` - Any unexpected exception raise by the event trigger functions are logged here

# Limitations and Restrictions
1. DDL which alters tables both replicated and non-replicated cannot be supported.  For example,
```
DROP TABLE replicated.foo, notreplicated.bar;
```

2. `CREATE TABLE AS` and `SELECT INTO` are not supported to replicate DDL due to limitations on transactional consistency.  That is, if a table is created from a set of data on the provider, to run the same SQL on the subscriber will in no way guarantee consistent data.  It is recommended instead that the DDL statement creating the table and the DML inserting into the table are separated.

3. If your DDL statement exceeds the length of `pg_stat_activity.query`, an unhandled exception will be logged.  It is recommended to run higher settings (10-15k for example) for `track_activity_query_size` to use this framework effectively.

4. If you mix DDL and DML, or replicated and non-replicated tables, in a single blob of SQL sent to client, this framework will not be able to distinguish these parts.  There is currently NO PROVISION to account for these edge cases.  It is very likely that such a transaction will error out on your subscriber and break replication.  Note that this framework will handle any of these mixed situations fine so long as the client is sending only one SQL statement through at a time, which is typical for many applications in terms of DDL deployment..
