#!/bin/bash
set -o errexit


# shellcheck disable=SC1091
. /usr/bin/utilities.sh


DEFAULT_PORT=3306
SSL_CIPHERS='DHE-RSA-AES256-SHA:AES128-SHA'
SERVER_ID_FILE=".aptible-server-id"


# MySQL 5.6 / 5.7 compatibility
if [[ "$MYSQL_VERSION" = "5.6" ]]; then
  SSL_CLIENT_OPT="--ssl"
  MYSQL_INSTALL_DB_BASE_COMMAND="mysql_install_db"
elif [[ "$MYSQL_VERSION" = "5.7" ]]; then
  SSL_CLIENT_OPT="--ssl-mode=REQUIRED"
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
  cp "${CONF_DIRECTORY}/conf.d/replication.cnf"{.template,}
  sed -i "s/__SERVER_ID__/${SERVER_ID}/g" "${CONF_DIRECTORY}/conf.d/replication.cnf"

  if [[ "${SERVER_ID}" -eq 1 ]]; then
    # We're the master, enable binary logging
    echo "log-bin = mysql-bin" >> "${CONF_DIRECTORY}/conf.d/replication.cnf"
  else
    # We're the slave, give our relay a fixed name
    echo "relay-log = mysql-relay" >> "${CONF_DIRECTORY}/conf.d/replication.cnf"
  fi

  ## Overrides configuration
  override_file="conf.d/overrides.cnf"
  # Useless use of cat, but makes the pipeline more readable.
  # shellcheck disable=SC2002
  cat "${CONF_DIRECTORY}/${override_file}.template" \
    | grep --fixed-strings --invert-match "__NOT_IF_MYSQL_${MYSQL_VERSION}__" \
    | sed "s:__DATA_DIRECTORY__:${DATA_DIRECTORY}:g" \
    | sed "s:__CONF_DIRECTORY__:${CONF_DIRECTORY}:g" \
    | sed "s/__PORT__/${PORT:-${DEFAULT_PORT}}/g" \
    | sed "s/__SSL_CIPHERS__/${SSL_CIPHERS}/g" \
    > "${CONF_DIRECTORY}/${override_file}"
}


function mysql_initialize_certs () {
  mkdir -p "$CONF_DIRECTORY/ssl"
  pushd "$CONF_DIRECTORY/ssl"

  # All of these certificates need to be generated and signed in the past.
  # Otherwise, MySQL can reject the configuration with an error indicating that
  # it thinks their start dates are in the future.
  faketime 'yesterday' openssl genrsa 2048 > ca-key.pem
  faketime 'yesterday' openssl req -sha1 -new -x509 -nodes -days 10000 -key ca-key.pem -batch > ca-cert.pem
  faketime 'yesterday' openssl req -sha1 -newkey rsa:2048 -days 10000 -nodes -keyout server-key-pkcs-8.pem -batch  > server-req.pem
  faketime 'yesterday' openssl x509 -sha1 -req -in server-req.pem -days 10000  -CA ca-cert.pem -CAkey ca-key.pem -set_serial 01 > server-cert.pem

  # MySQL requires the key to be PKCS #1-formatted; modern versions of OpenSSL
  # will generate a key in PKCS #8 format. This call ensures that the key is in
  # PKCS #1 format. Reference: https://bugs.mysql.com/bug.php?id=71271
  openssl rsa -in server-key-pkcs-8.pem -out server-key.pem

  popd
}


function mysql_initialize_data_dir () {
  chown -R mysql:mysql "$DATA_DIRECTORY"
  $MYSQL_INSTALL_DB_BASE_COMMAND --user=mysql --datadir="$DATA_DIRECTORY"
}


function mysql_start_background () {
  mysqld_safe --defaults-file="${CONF_DIRECTORY}/my.cnf" --ssl &
  until nc -z localhost 3306; do sleep 0.1; done
}

function mysql_start_foreground () {
  unset SSL_CERTIFICATE
  unset SSL_KEY
  exec mysqld_safe --defaults-file="${CONF_DIRECTORY}/my.cnf" --ssl "$@"
}


function mysql_shutdown () {
  mysqladmin shutdown
}


if [[ "$1" == "--initialize" ]]; then
  # We're initializing a master; use server-id = 1.
  mkdir -p "$(dirname "${DATA_DIRECTORY}/${SERVER_ID_FILE}")"
  echo 1 > "${DATA_DIRECTORY}/${SERVER_ID_FILE}"

  mysql_initialize_certs
  mysql_initialize_conf_dir
  mysql_initialize_data_dir
  mysql_start_background

  # Create our DB
  mysql -e "CREATE DATABASE ${DATABASE:-db}"

  # Create Aptible users, set passwords
  mysql -e "GRANT ALL ON *.* to 'root'@'%' IDENTIFIED BY '$PASSPHRASE' WITH GRANT OPTION"  # Required to grant replication permissions
  mysql -e "GRANT ALL ON ${DATABASE:-db}.* to '${USERNAME:-aptible}-nossl'@'%' IDENTIFIED BY '$PASSPHRASE'"
  mysql -e "GRANT ALL ON ${DATABASE:-db}.* to '${USERNAME:-aptible}'@'%' IDENTIFIED BY '$PASSPHRASE' REQUIRE SSL"

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

  # shellcheck disable=SC2154
  MYSQL_PWD="$password" mysql --host "$host" --port "${port:-$DEFAULT_PORT}" --user "${MYSQL_REPLICATION_ROOT}" "$SSL_CLIENT_OPT" --ssl-cipher="${SSL_CIPHERS}" \
    --execute "
    CREATE USER '$MYSQL_REPLICATION_USERNAME'@'$MYSQL_REPLICATION_HOST' IDENTIFIED BY '$MYSQL_REPLICATION_PASSPHRASE';
    GRANT REPLICATION SLAVE ON *.* TO '$MYSQL_REPLICATION_USERNAME'@'$MYSQL_REPLICATION_HOST' REQUIRE SSL;
  "

  MASTER_DUMPFILE=/tmp/master.dump

  # Create slave configuration
  echo "$MYSQL_REPLICATION_SLAVE_SERVER_ID" > "${DATA_DIRECTORY}/${SERVER_ID_FILE}"

  mysql_initialize_certs
  mysql_initialize_conf_dir
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
  MYSQL_PWD="$password" mysqldump --host "$host" --port "${port:-$DEFAULT_PORT}" --user "$MYSQL_REPLICATION_ROOT" "$SSL_CLIENT_OPT" --ssl-cipher="${SSL_CIPHERS}" \
    --all-databases --master-data \
    > "${MASTER_DUMPFILE}"

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
  mysql < "${MASTER_DUMPFILE}"

  mysql_shutdown

  # Cleanup
  rm "${MASTER_DUMPFILE}"

elif [[ "$1" == "--client" ]]; then
  [ -z "$2" ] && echo "docker run -it aptible/mysql --client mysql://..." && exit
  parse_url "$2"

  shift
  shift

  # shellcheck disable=SC2154
  MYSQL_PWD="$password" mysql --host="$host" --port "${port:-$DEFAULT_PORT}" --user="$user" "$database" "$SSL_CLIENT_OPT" --ssl-cipher="${SSL_CIPHERS}" "$@"

elif [[ "$1" == "--dump" ]]; then
  [ -z "$2" ] && echo "docker run aptible/mysql --dump mysql://... > dump.sql" && exit
  parse_url "$2"

  # If the file /dump-output exists, write output there. Otherwise, use stdout.
  # shellcheck disable=SC2015
  [ -e /dump-output ] && exec 3>/dump-output || exec 3>&1

  # shellcheck disable=SC2154
  MYSQL_PWD="$password" mysqldump --host="$host" --port "${port:-$DEFAULT_PORT}" --user="$user" "$database" "$SSL_CLIENT_OPT" --ssl-cipher="${SSL_CIPHERS}" >&3

elif [[ "$1" == "--restore" ]]; then
  [ -z "$2" ] && echo "docker run -i aptible/mysql --restore mysql://... < dump.sql" && exit
  parse_url "$2"

  # If the file /restore-input exists, read input there. Otherwise, use stdin.
  # shellcheck disable=SC2015
  [ -e /restore-input ] && exec 3</restore-input || exec 3<&0
  MYSQL_PWD="$password" mysql --host="$host" --port "${port:-$DEFAULT_PORT}" --user="$user" "$database" "$SSL_CLIENT_OPT" --ssl-cipher="${SSL_CIPHERS}" <&3

elif [[ "$1" == "--readonly" ]]; then
  echo "Starting MySQL in read-only mode..."
  mysql_initialize_certs
  mysql_initialize_conf_dir
  mysql_start_foreground --read-only

else
  mysql_initialize_certs
  mysql_initialize_conf_dir
  mysql_start_foreground
fi
