#!/usr/bin/env bats

setup() {
  export OLD_DATA_DIRECTORY="$DATA_DIRECTORY"
  export OLD_CONF_DIRECTORY="$CONF_DIRECTORY"
  export OLD_LOG_DIRECTORY="$LOG_DIRECTORY"
  export DATA_DIRECTORY=/tmp/datadir
  export CONF_DIRECTORY=/tmp/confdir
  export LOG_DIRECTORY=/tmp/logdir
  mkdir "$DATA_DIRECTORY" "$LOG_DIRECTORY"
  chown -R mysql:mysql "$LOG_DIRECTORY"
  cp -r "$OLD_CONF_DIRECTORY" "$CONF_DIRECTORY"  # Templates are in there

  PASSPHRASE=foobar /usr/bin/run-database.sh --initialize
  while [ -f /var/run/mysqld/mysqld.pid ]; do sleep 0.1; done

  export LOG_FILE="/tmp/mysql.log"
  /usr/bin/run-database.sh > "$LOG_FILE" 2>&1 &
  until mysqladmin ping; do sleep 0.1; done
}

teardown() {
  pkill --signal KILL tail

  mysqladmin shutdown
  while [ -f /var/run/mysqld/mysqld.pid ]; do sleep 0.1; done

  cat "$LOG_FILE"
  rm -f "$LOG_FILE"
  unset LOG_FILE

  rm -rf "$DATA_DIRECTORY"
  rm -rf "$CONF_DIRECTORY"
  rm -rf "$LOG_DIRECTORY"
  export DATA_DIRECTORY="$OLD_DATA_DIRECTORY"
  export CONF_DIRECTORY="$OLD_CONF_DIRECTORY"
  export LOG_DIRECTORY="$OLD_LOG_DIRECTORY"
  unset OLD_DATA_DIRECTORY
  unset OLD_CONF_DIRECTORY
  unset OLD_LOG_DIRECTORY
}

@test "It should install MySQL $MYSQL_PACKAGE_VERSION" {
  run mysqld --version
  [[ "$output" =~ "Ver ${MYSQL_PACKAGE_VERSION%%-*}" ]]  # Package version up to -
}

@test "It should bring up a working MySQL instance with aptible and aptible-nossl users" {
  for user in aptible aptible-nossl; do
    url="mysql://${user}:foobar@127.0.0.1:3306/db"
    run-database.sh --client "$url" -e "DROP TABLE IF EXISTS foo;"
    run-database.sh --client "$url" -e "CREATE TABLE foo (i INT);"
    run-database.sh --client "$url" -e "INSERT INTO foo VALUES (1234);"
    run run-database.sh --client "$url" -e "SELECT * FROM foo;"
    [ "$status" -eq "0" ]
    [ "${lines[0]}" = "i" ]
    [ "${lines[1]}" = "1234" ]
  done
}

@test "It should support SSL connections" {
  have_ssl=$(run-database.sh --client "mysql://root@localhost/db" -Ee "show variables where variable_name = 'have_ssl'" | grep Value | awk '{ print $2 }')
  [[ "$have_ssl" == "YES" ]]
}

@test "It should be built with OpenSSL support" {
  have_openssl=$(run-database.sh --client "mysql://root@localhost/db" -Ee "show variables where variable_name = 'have_openssl'" | grep Value | awk '{ print $2 }')
  [[ "$have_openssl" == "YES" ]]
}

@test "It should allow connections over SSL" {
  cipher=$(run-database.sh --client "mysql://root@localhost/db" -Ee "show status like 'Ssl_cipher'" | grep Value | awk '{ print $2 }')
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

@test "It should not let users read private key material" {
  mysql db -e "CREATE TABLE data (col TEXT);"
  run mysql db -e "LOAD DATA INFILE '/etc/mysql/ssl/server-key.pem' INTO TABLE data;"
  [[ "$status" -eq 1 ]]
  [[ "$output" =~ "cannot execute this statement" ]]
}

@test "It should not log queries by default, but log to stdout when enabled" {
  truncate -s 0 "$LOG_FILE"

  canary='hello from the log file'
  mysql db -e "SELECT '$canary';"
  ! grep -q "$canary" "$LOG_FILE"

  mysql db -e "SET GLOBAL general_log = 1;"
  mysql db -e "SELECT '$canary';"

  sleep 2 # in case we're being slow for some reason. not ideal but we'll be OK

  grep -Eq "general.*${canary}" "$LOG_FILE"
}

@test "It should not slow log queries by default, but log them to stdout when enabled" {
  truncate -s 0 "$LOG_FILE"

  mysql db -e "SET GLOBAL long_query_time = 1;"
  mysql db -e "SELECT SLEEP(3);"
  ! grep -q "SLEEP" "$LOG_FILE"

  mysql db -e "SET GLOBAL slow_query_log = 1;"
  mysql db -e "SELECT SLEEP(3);"

  sleep 2 # same as above

  grep -Eq "slow.*SLEEP" "$LOG_FILE"
}
