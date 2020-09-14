#!/bin/bash

set -eu

orig_path=$PATH

unset PGSERVICE

set_path() {
version=$1
export PATH=/usr/lib/postgresql/$version/bin:$orig_path
}

get_port() {
version=$1
pg_lsclusters | awk -v version=$version '$1 == version { print $3 }'
}

make_and_test() {
version=$1
from_version=$2
set_path $version
make clean
sudo "PATH=$PATH" make uninstall
sudo "PATH=$PATH" make install
port=$(get_port $version)
PGPORT=$port psql postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'contrib_regression' AND pid <> pg_backend_pid()"
FROMVERSION=$from_version PGPORT=$port make installcheck
}

test_all_versions() {
from_version="$1"
cat << EOM

*******************FROM VERSION $from_version******************

EOM
#make_and_test "9.5" $from_version
#make_and_test "9.6" $from_version
#make_and_test "10" $from_version
#make_and_test "11" $from_version
make_and_test "12" $from_version
#make_and_test "13" $from_version
}
test_all_versions "2.0"
#test_all_versions "1.7"
#test_all_versions "1.6"
#test_all_versions "1.5"
