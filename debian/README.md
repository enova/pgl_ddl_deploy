# Debian/Ubuntu packaging
This directory contains the Debian control section for pgl_ddl_deploy packages.

## How to Use This
1. Edit the `debian/changelog` file.
2. Run the following command in the top level source directory to build all source and binary packages.
```
debuild -us -uc
```

## New major version of PostgreSQL?
Install the appropriate development packages.  The debian/control file needs to be updated.
Use the following command in the top level source directory:
```
pg_buildext updatecontrol
```
