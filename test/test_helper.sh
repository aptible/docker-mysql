#!/bin/bash

start_mysql() {
  initialize_mysql
  run_server
}

stop_mysql() {
  stop_server
  cleanup_mysql
}


initialize_mysql() {
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
}

run_server() {
  export LOG_FILE="/tmp/mysql.log"
  /usr/bin/run-database.sh > "$LOG_FILE" 2>&1 &
  until mysqladmin ping; do sleep 0.1; done
}

stop_server () {
  pkill --signal KILL tail

  mysqladmin shutdown
  while [ -f /var/run/mysqld/mysqld.pid ]; do sleep 0.1; done
}

cleanup_mysql() {
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