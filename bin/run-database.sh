#!/bin/bash
set -o errexit

# shellcheck disable=SC1091
. /usr/bin/utilities.sh


DEFAULT_PORT=3306
SSL_CIPHERS='DHE-RSA-AES256-SHA:AES128-SHA'
SERVER_ID_FILE=".aptible-server-id"
INNODB_LOG_SIZE_CONFIG=".aptible-innodb-log-file-size"

SSL_DIRECTORY="${CONF_DIRECTORY}/ssl"

MYSQL_LOG_FILES=(
  "${LOG_DIRECTORY}/general.log"
  "${LOG_DIRECTORY}/slow.log"
)


# MySQL 5.6 / 5.7 compatibility
if [[ "$MYSQL_VERSION" = "5.6" ]]; then
  MYSQL_INSTALL_DB_BASE_COMMAND="mysql_install_db"
elif [[ "$MYSQL_VERSION" = "5.7" ]]; then
  MYSQL_INSTALL_DB_BASE_COMMAND="mysqld --initialize-insecure"
elif [[ "$MYSQL_VERSION" = "8.0" ]]; then
  MYSQL_INSTALL_DB_BASE_COMMAND="mysqld --initialize-insecure"
else
  echo "Unrecognized MYSQL_VERSION: $MYSQL_VERSION"
  exit 1
fi


function mysql_initialize_conf_dir () {
  # Verify the server id exists for backwards compatibility with databases created
  # on older versions of this image.
  if [[ ! -f "${DATA_DIRECTORY}/${SERVER_ID_FILE}" ]]; then
    echo 1 > "${DATA_DIRECTORY}/${SERVER_ID_FILE}"
  fi

  SERVER_ID="$(cat "${DATA_DIRECTORY}/${SERVER_ID_FILE}")"

  ## My.cnf
  cp "${CONF_DIRECTORY}/my.cnf"{.template,}
  sed -i "s:__CONF_DIRECTORY__:${CONF_DIRECTORY}:g" "${CONF_DIRECTORY}/my.cnf"

  ## Replication configuration
  replication_file="replication.cnf"
  # shellcheck disable=SC2002
  cat "${CONF_DIRECTORY}/conf.d/${replication_file}.template" \
    | sed "s/__SERVER_ID__/${SERVER_ID}/g" \
    > "${CONF_DIRECTORY}/conf.d/00-${replication_file}"

  ## Overrides configuration (read first)
  override_file="overrides.cnf"
  # Useless use of cat, but makes the pipeline more readable.
  # shellcheck disable=SC2002
  cat "${CONF_DIRECTORY}/conf.d/${override_file}.template" \
    | grep --fixed-strings --invert-match "__NOT_IF_MYSQL_${MYSQL_VERSION}__" \
    | sed "s:__DATA_DIRECTORY__:${DATA_DIRECTORY}:g" \
    | sed "s:__CONF_DIRECTORY__:${CONF_DIRECTORY}:g" \
    | sed "s:__SCRATCH_DIRECTORY__:${SCRATCH_DIRECTORY}:g" \
    | sed "s:__LOG_DIRECTORY__:${LOG_DIRECTORY}:g" \
    | sed "s/__PORT__/${PORT:-${DEFAULT_PORT}}/g" \
    | sed "s/__SSL_CIPHERS__/${SSL_CIPHERS}/g" \
    > "${CONF_DIRECTORY}/conf.d/01-${override_file}"

  # Auto-tune (takes precedence on overrides)
  /usr/local/bin/autotune > "${CONF_DIRECTORY}/conf.d/10-autotune.cnf"

  # Read an optional config file from the persistent volume (taks precedence over all)
  persist_file="persist.cnf"
  EXTRA_FILE="${DATA_DIRECTORY}/${persist_file}"
  if [ -f "$EXTRA_FILE" ]; then
    cp "${EXTRA_FILE}" "${CONF_DIRECTORY}/conf.d/20-${persist_file}"
  fi

  # Finally, copy over the InnoDB log file size configuration, if it exists (we
  # used to not create this file). Nothing should be allowed to take precedence
  # over this file.
  if [[ -f "${DATA_DIRECTORY}/${INNODB_LOG_SIZE_CONFIG}" ]]; then
    cp "${DATA_DIRECTORY}/${INNODB_LOG_SIZE_CONFIG}" \
       "${CONF_DIRECTORY}/conf.d/99-innodb-log-file-size.cnf"
  fi
}


function mysql_initialize_certs () {
  mkdir -p "$SSL_DIRECTORY"
  pushd "$SSL_DIRECTORY"

  local ssl_cert_file="server-cert.pem"
  local ssl_key_file="server-key.pem"

  if [ -n "$SSL_CERTIFICATE" ] && [ -n "$SSL_KEY" ]; then
    echo "Certs present in environment - using them"
    echo "$SSL_CERTIFICATE" > "$ssl_cert_file"
    echo "$SSL_KEY" > "$ssl_key_file"
  else
    # All of these certificates need to be generated and signed in the past.
    # Otherwise, MySQL can reject the configuration with an error indicating that
    # it thinks their start dates are in the future.
    faketime 'yesterday' openssl genrsa 2048 > ca-key.pem
    faketime 'yesterday' openssl req -sha1 -new -x509 -nodes -days 10000 -key ca-key.pem -batch > ca-cert.pem
    faketime 'yesterday' openssl req -sha1 -newkey rsa:2048 -days 10000 -nodes -keyout server-key-pkcs-8.pem -batch  > server-req.pem
    faketime 'yesterday' openssl x509 -sha1 -req -in server-req.pem -days 10000  -CA ca-cert.pem -CAkey ca-key.pem -set_serial 01 > "$ssl_cert_file"

    # MySQL requires the key to be PKCS #1-formatted; modern versions of OpenSSL
    # will generate a key in PKCS #8 format. This call ensures that the key is in
    # PKCS #1 format. Reference: https://bugs.mysql.com/bug.php?id=71271
    openssl rsa -in server-key-pkcs-8.pem -out "$ssl_key_file"
  fi

  chown mysql:mysql "$ssl_cert_file" "$ssl_key_file"

  popd
}


function mysql_initialize_log_dir () {
  # This directory isn't mounted, so we never need to re-initialize it.
  touch "${MYSQL_LOG_FILES[@]}"
  chown mysql:mysql "${MYSQL_LOG_FILES[@]}"
}


function mysql_initialize_data_dir () {
  chown -R mysql:mysql "$DATA_DIRECTORY"
  $MYSQL_INSTALL_DB_BASE_COMMAND --user=mysql --datadir="$DATA_DIRECTORY"
}


function wait_for_mysql_nc {
  for _ in $(seq 1 30); do
    if nc -z localhost 3306; then
      return 0
    fi

    sleep 2
  done

  return 1
}

function wait_for_mysql_ping {
  for _ in $(seq 1 30); do
    if mysqladmin ping; then
      return 0
    fi

    sleep 2
  done

  return 1
}

function mysql_start_background () {
  /usr/sbin/mysqld \
    --defaults-file="${CONF_DIRECTORY}/my.cnf" \
    --bind-address=127.0.0.1 \
    --ssl \
    --performance-schema="$MYSQL_PERFORMANCE_SCHEMA" \
    &

  wait_for_mysql_nc
  wait_for_mysql_ping
}

function mysql_start_foreground () {
  # See: http://unix.stackexchange.com/a/337779
  for log in "${MYSQL_LOG_FILES[@]}"; do
    tail -n 0 --quiet -F "$log" 2>&1 | sed -ue "s/^/$(basename "$log"): /" &
  done

  exec /usr/sbin/mysqld \
    --defaults-file="${CONF_DIRECTORY}/my.cnf" \
    --ssl \
    --performance-schema="$MYSQL_PERFORMANCE_SCHEMA" \
    "$@"
}


function mysql_shutdown () {
  mysqladmin shutdown
}

function mysql_initialize_innodb_log_file_size() {
  local file="${DATA_DIRECTORY}/${INNODB_LOG_SIZE_CONFIG}"

  # This file can should be initialized once, since older versions of MySQL
  # will refuse to start if we change its value.
  if [[ -f "$file" ]]; then
    echo "The innodb_log_file_size (${file}) file already exists!"
    return 1
  fi

  mkdir -p "$(dirname "$file")"

  # We set the size of the log files to 256M, which is the value Percona
  # recommends as "a good place to start". Considering that, by default,
  # databases on Enclave have 10GB of disk, this is a reasonable value.
  printf '[mysqld]\ninnodb_log_file_size=%s\n' 256M > "${file}"
}


if [[ "$1" == "--initialize" ]]; then
  # We're initializing a master; use server-id = 1.
  mkdir -p "$(dirname "${DATA_DIRECTORY}/${SERVER_ID_FILE}")"
  echo 1 > "${DATA_DIRECTORY}/${SERVER_ID_FILE}"
  mysql_initialize_innodb_log_file_size

  mysql_initialize_certs
  mysql_initialize_conf_dir
  mysql_initialize_log_dir
  mysql_initialize_data_dir

  mysql_start_background

  # Create our DB
  mysql -e "CREATE DATABASE ${DATABASE:-db}"

  # Create Aptible users, set passwords
  # NOTE: GRANT OPTION is required to grant replication permissions
  if [[ "$MYSQL_VERSION" = "5.6" ]] || [[ "$MYSQL_VERSION" = "5.7" ]]; then
    mysql -e "GRANT ALL ON *.* to 'root'@'%' IDENTIFIED BY '$PASSPHRASE' WITH GRANT OPTION"
    mysql -e "GRANT ALL ON ${DATABASE:-db}.* to '${USERNAME:-aptible}-nossl'@'%' IDENTIFIED BY '$PASSPHRASE'"
    mysql -e "GRANT ALL ON ${DATABASE:-db}.* to '${USERNAME:-aptible}'@'%' IDENTIFIED BY '$PASSPHRASE' REQUIRE SSL"
  else
    mysql -e "CREATE USER 'root'@'%' IDENTIFIED BY '$PASSPHRASE'"
    mysql -e "CREATE USER '${USERNAME:-aptible}-nossl'@'%' IDENTIFIED BY '$PASSPHRASE'"
    mysql -e "CREATE USER '${USERNAME:-aptible}'@'%' IDENTIFIED BY '$PASSPHRASE' REQUIRE SSL"

    mysql -e "GRANT ALL ON *.* to 'root'@'%' WITH GRANT OPTION"
    mysql -e "GRANT ALL ON ${DATABASE:-db}.* to '${USERNAME:-aptible}-nossl'@'%'"
    mysql -e "GRANT ALL ON ${DATABASE:-db}.* to '${USERNAME:-aptible}'@'%'"
  fi

  # Delete all anonymous users. We don't use (or want those), but more importantly they prevent
  # legitimate users from authenticating from hosts where anonymous users can login (because MySQL
  # matches the anonymous users first), which includes localhost.
  # https://bugs.mysql.com/bug.php?id=31061
  mysql -e "DELETE FROM mysql.user WHERE User='';"
  mysql -e "FLUSH PRIVILEGES;"  # Probably not useful since we're shutting down; but who knows.

  mysql_shutdown

elif [[ "$1" == "--initialize-from" ]]; then
  [ -z "$2" ] && echo "docker run -it aptible/mysql --initialize-from mysql://..." && exit 1

  # First, generate a new server ID for this slave unless one is provided. We'll use it for the username, too.
  # In MySQL < 5.7, usernames must be <= 16 chars, and replication password must be < 32 chars.

  # shellcheck disable=SC2086
  {
    : ${MYSQL_REPLICATION_SLAVE_SERVER_ID:="$(randint_32)"}
    : ${MYSQL_REPLICATION_USERNAME:="repl-$MYSQL_REPLICATION_SLAVE_SERVER_ID"}
    : ${MYSQL_REPLICATION_PASSPHRASE:="$(random_chars 16)"}
    : ${MYSQL_REPLICATION_HOST:="%"}
    : ${MYSQL_REPLICATION_ROOT:="root"}  # By default, ignore user from URL and use root to reconfigure existing MySQL
  }

  parse_url "$2"

  # Ensure port has a value from here on
  port="${port:-$DEFAULT_PORT}"

  # CREATE USER will fail if the user already exists, which we want here.
  # We could retry, but the probability that we'll use twice the same ID
  # with 2**32 choices is pretty low (< 1% even if we spin up 9000 slaves).

  # In MySQL 8, REQUIRE SSL neds to be provided on CREATE USER, but in MySQL <
  # 8, it needs to be provided in GRANT. Depending on our version, we do one or
  # the other. This assumes our MySQL version and the primary's are the same,
  # which is how we normally initialize slaves.

  create_user_ssl="REQUIRE SSL"
  grant_ssl=""

  if [[ "$MYSQL_VERSION" = "5.6" ]] || [[ "$MYSQL_VERSION" = "5.7" ]]; then
    create_user_ssl=""
    grant_ssl="REQUIRE SSL"
  fi

  # shellcheck disable=SC2154
  MYSQL_PWD="$password" mysql --host "$host" --port "${port:-$DEFAULT_PORT}" --user "${MYSQL_REPLICATION_ROOT}" --ssl-mode=REQUIRED --ssl-cipher="${SSL_CIPHERS}" \
    --execute "
    CREATE USER '$MYSQL_REPLICATION_USERNAME'@'$MYSQL_REPLICATION_HOST' IDENTIFIED BY '$MYSQL_REPLICATION_PASSPHRASE' $create_user_ssl;
    GRANT REPLICATION SLAVE ON *.* TO '$MYSQL_REPLICATION_USERNAME'@'$MYSQL_REPLICATION_HOST' $grant_ssl;
  "

  MASTER_DUMPFILE=/tmp/master.dump

  PRIVILEGES_DUMPFILE=/tmp/master.dump
  DATA_DUMPFILE=/tmp/db.dump

  # Create slave configuration
  echo "$MYSQL_REPLICATION_SLAVE_SERVER_ID" > "${DATA_DIRECTORY}/${SERVER_ID_FILE}"

  mysql_initialize_innodb_log_file_size

  mysql_initialize_certs
  mysql_initialize_conf_dir
  mysql_initialize_log_dir
  mysql_initialize_data_dir

  # Now, retrieve data from the master
  # Note that this will fail if binary logging is not enabled on the master (because we use --master-data, which
  # is expected to include the binary log position), which is good.

  # TODO - Do we want to enable --single-transaction? This would be preferable because right now
  # we'll acquire locks that will slow down any currently running application (which is bad).
  # If we use --single-transaction, that won't be the case, but:
  # - It only works properly with InnoDB tables, but MySQL won't enforce it.
  # - There can't be any data definition operations (e.g. ALTER TABLE happening at the same time), but
  #   MySQL won't enforce it.

  # shellcheck disable=SC2154
  MYSQL_PWD="$password" mysqldump --host "$host" --port "${port:-$DEFAULT_PORT}" --user "$MYSQL_REPLICATION_ROOT" --ssl-mode=REQUIRED --ssl-cipher="${SSL_CIPHERS}" \
    mysql --flush-privileges \
    > "${PRIVILEGES_DUMPFILE}"

   # shellcheck disable=SC2154
  MYSQL_PWD="$password" mysqldump --host "$host" --port "${port:-$DEFAULT_PORT}" --user "$MYSQL_REPLICATION_ROOT" --ssl-mode=REQUIRED --ssl-cipher="${SSL_CIPHERS}" \
    --master-data --all-databases \
    > "${DATA_DUMPFILE}"

  # Launch MySQL, load the data in, then start the slave.
  # The slave will restart automatically next time MySQL starts up.

  mysql_start_background

  # Change MASTER_PORT *must* be run before loading the dump, otherwise MySQL
  # will assume the master has changed and reset the positions set by the dump...
  # http://dev.mysql.com/doc/refman/5.6/en/change-master-to.html
  # shellcheck disable=SC2154
  mysql -e "CHANGE MASTER TO
    MASTER_HOST = '${host}',
    MASTER_PORT = ${port},
    MASTER_USER = '${MYSQL_REPLICATION_USERNAME}',
    MASTER_PASSWORD = '${MYSQL_REPLICATION_PASSPHRASE}',
    MASTER_SSL = 1,
    MASTER_SSL_CIPHER = '${SSL_CIPHERS}';"

  # Load initial data and log position
  mysql mysql < "${PRIVILEGES_DUMPFILE}"
  mysql < "${DATA_DUMPFILE}"

  mysql_shutdown

  # Cleanup
  rm "${PRIVILEGES_DUMPFILE}" "${DATA_DUMPFILE}"

elif [[ "$1" == "--client" ]]; then
  [ -z "$2" ] && echo "docker run -it aptible/mysql --client mysql://..." && exit
  parse_url "$2"

  shift
  shift

  # shellcheck disable=SC2154
  MYSQL_PWD="$password" mysql --host="$host" --port "${port:-$DEFAULT_PORT}" --user="$user" "$database" --ssl-mode=REQUIRED --ssl-cipher="${SSL_CIPHERS}" "$@"

elif [[ "$1" == "--dump" ]]; then
  [ -z "$2" ] && echo "docker run aptible/mysql --dump mysql://... > dump.sql" && exit
  parse_url "$2"

  # If the file /dump-output exists, write output there. Otherwise, use stdout.
  # shellcheck disable=SC2015
  [ -e /dump-output ] && exec 3>/dump-output || exec 3>&1

  # shellcheck disable=SC2154
  MYSQL_PWD="$password" mysqldump --host="$host" --port "${port:-$DEFAULT_PORT}" --user="$user" "$database" --ssl-mode=REQUIRED --ssl-cipher="${SSL_CIPHERS}" >&3

elif [[ "$1" == "--restore" ]]; then
  [ -z "$2" ] && echo "docker run -i aptible/mysql --restore mysql://... < dump.sql" && exit
  parse_url "$2"

  # If the file /restore-input exists, read input there. Otherwise, use stdin.
  # shellcheck disable=SC2015
  [ -e /restore-input ] && exec 3</restore-input || exec 3<&0
  MYSQL_PWD="$password" mysql --host="$host" --port "${port:-$DEFAULT_PORT}" --user="$user" "$database" --ssl-mode=REQUIRED --ssl-cipher="${SSL_CIPHERS}" <&3

elif [[ "$1" == "--readonly" ]]; then
  echo "Starting MySQL in read-only mode..."
  mysql_initialize_certs
  mysql_initialize_conf_dir
  mysql_initialize_log_dir
  mysql_start_foreground --read-only

else
  mysql_initialize_certs
  mysql_initialize_conf_dir
  mysql_initialize_log_dir
  mysql_start_foreground
fi
