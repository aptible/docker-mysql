#!/usr/bin/env bats

setup() {
  export OLD_DATA_DIRECTORY="$DATA_DIRECTORY"
  export DATA_DIRECTORY=/tmp/datadir
  mkdir "$DATA_DIRECTORY"
  /usr/bin/run-database.sh --initialize
  while [ -f /var/run/mysqld/mysqld.pid ]; do sleep 0.1; done
  /usr/bin/run-database.sh > /tmp/mysql.log 2>&1 &
  until mysqladmin ping; do sleep 0.1; done
}

teardown() {
  mysqladmin shutdown
  while [ -f /var/run/mysqld/mysqld.pid ]; do sleep 0.1; done
  rm -rf "$DATA_DIRECTORY"
  export DATA_DIRECTORY="$OLD_DATA_DIRECTORY"
  unset OLD_DATA_DIRECTORY
}

@test "It should install MySQL 5.6.28" {
  run mysqld --version
  [[ "$output" =~ "Ver 5.6.28"  ]]
}

@test "It should support SSL connections" {
  have_ssl=$(mysql -Ee "show variables where variable_name = 'have_ssl'" | grep Value | awk '{ print $2 }')
  [[ "$have_ssl" == "YES" ]]
}

@test "It should be built with OpenSSL support" {
  have_openssl=$(mysql -Ee "show variables where variable_name = 'have_openssl'" | grep Value | awk '{ print $2 }')
  [[ "$have_openssl" == "YES" ]]
}

@test "It should allow connections over SSL" {
  cipher=$(mysql -Ee "show status like 'Ssl_cipher'" | grep Value | awk '{ print $2 }')
  [[ "$cipher" == "DHE-RSA-AES256-SHA" ]]
}

@test "It should set max_connect_errors to a large value" {
# Containers from this Docker image are often run behind load balancers that
# ping them constantly with TCP health checks, which can confuse MySQL because
# they appear to be repeated failed connection attempts from the same host.
# MySQL will eventually block connections from the load balancer if
# max_connect_errors isn't set high enough.
  max_connect_errors=$(mysql -Ee "show variables where variable_name = 'max_connect_errors'" | grep Value | awk '{ print $2 }')
  [[ "$max_connect_errors" -ge 10000000 ]]
}

@test "It should dump to stdout by default" {
  run /usr/bin/run-database.sh --dump mysql://root@localhost/db
  [ "$status" -eq "0" ]
  [[ "${lines[0]}" =~ "-- MySQL dump 10.13" ]]
  [[ "${lines[-1]}" =~ "-- Dump completed" ]]
}

@test "It should restore from stdin by default" {
  /usr/bin/run-database.sh --dump mysql://root@localhost/db > /tmp/restore-test
  echo "CREATE TABLE foo (i int);" >> /tmp/restore-test
  echo "INSERT INTO foo VALUES (1);" >> /tmp/restore-test
  run /usr/bin/run-database.sh --restore mysql://root@localhost/db < /tmp/restore-test
  [ "$status" -eq "0" ]
  rm /tmp/restore-test
  run mysql -Ee "SELECT * FROM foo" db
  [ "$status" -eq "0" ]
  [ "${lines[1]}" = "i: 1" ]
  [ "${#lines[@]}" = "2" ]
}

@test "It should dump to /dump-output if /dump-output exists" {
  touch /dump-output
  run /usr/bin/run-database.sh --dump mysql://root@localhost/db
  [ "$status" -eq "0" ]
  [ "$output" = "" ]
  run cat dump-output
  rm /dump-output
  [[ "${lines[0]}" =~ "-- MySQL dump 10.13" ]]
  [[ "${lines[-1]}" =~ "-- Dump completed" ]]
}

@test "It should restore from /restore-input if /restore-input exists" {
  /usr/bin/run-database.sh --dump mysql://root@localhost/db > /restore-input
  echo "CREATE TABLE foo (i int);" >> /restore-input
  echo "INSERT INTO foo VALUES (1);" >> /restore-input
  run /usr/bin/run-database.sh --restore mysql://root@localhost/db
  [ "$status" -eq "0" ]
  rm /restore-input
  run mysql -Ee "SELECT * FROM foo" db
  [ "$status" -eq "0" ]
  [ "${lines[1]}" = "i: 1" ]
  [ "${#lines[@]}" = "2" ]
}
