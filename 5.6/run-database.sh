#!/bin/bash
set -o errexit

. /usr/bin/utilities.sh


SSL_CIPHER='DHE-RSA-AES256-SHA'


function mysql_initialize_conf_dir () {
  # Verify the server id exists for backwards compatibility with databases created
  # on older versions of this image.
  if [[ ! -f "${DATA_DIRECTORY}/server-id" ]]; then
    echo 1 > "${DATA_DIRECTORY}/server-id"
  fi

  SERVER_ID="$(cat "${DATA_DIRECTORY}/server-id")"

  cp /etc/mysql/conf.d/replication.cnf.template /etc/mysql/conf.d/replication.cnf
  sed -i "s/__SERVER_ID__/${SERVER_ID}/g" /etc/mysql/conf.d/replication.cnf

  if [[ "${SERVER_ID}" -eq 1 ]]; then
    # We're the master, enable binary logging
    echo "log-bin = mysql-bin" >> /etc/mysql/conf.d/replication.cnf
  fi

  sed "s:DATA_DIRECTORY:${DATA_DIRECTORY}:g" /etc/mysql/conf.d/overrides.cnf.template > /etc/mysql/conf.d/overrides.cnf
}


function mysql_initialize_certs () {
  mkdir -p "$DATA_DIRECTORY/ssl"
  pushd "$DATA_DIRECTORY/ssl"

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
  mysql_install_db --user=mysql -ldata="$DATA_DIRECTORY"
}


function mysql_start_background () {
  mysqld_safe --ssl &
  until nc -z localhost 3306; do sleep 0.1; done
}


function mysql_shutdown () {
  mysqladmin shutdown
}


if [[ "$1" == "--initialize" ]]; then
  # We're initializing a master. Use server-id = 1.
  echo 1 > "${DATA_DIRECTORY}/server-id"

  mysql_initialize_certs
  mysql_initialize_data_dir
  mysql_initialize_conf_dir
  mysql_start_background

  mysql -e "CREATE DATABASE ${DATABASE:-db}"
  mysql -e "GRANT ALL ON *.* to 'root'@'%' IDENTIFIED BY '$PASSPHRASE' WITH GRANT OPTION"  # Required to grant replication permissions
  mysql -e "GRANT ALL ON ${DATABASE:-db}.* to '${USERNAME:-aptible}-nossl'@'%' IDENTIFIED BY '$PASSPHRASE'"
  mysql -e "GRANT ALL ON ${DATABASE:-db}.* to '${USERNAME:-aptible}'@'%' IDENTIFIED BY '$PASSPHRASE' REQUIRE SSL"

  mysql_shutdown

elif [[ "$1" == "--activate-leader" ]]; then
  [ -z "$2" ] && echo "docker run -it aptible/mysql --activate-leader mysql://..." && exit 1
  # First, generate a new server ID for the slave unless one is provided. We'll use it for the username, too.
  # In MySQL < 5.7, usernames must be <= 16 chars, and replication password must be < 32 chars.
  : ${MYSQL_REPLICATION_SLAVE_SERVER_ID:="$(randint_32)"}
  : ${MYSQL_REPLICATION_USERNAME:="repl-$MYSQL_REPLICATION_SLAVE_SERVER_ID"}
  : ${MYSQL_REPLICATION_PASSPHRASE:="$(random_chars 16)"}
  : ${MYSQL_REPLICATION_HOST:="%"}

  parse_url "$2"

  # CREATE USER will fail if the user already exists, which we want here.
  # We could retry, but the probability that we'll use twice the same ID
  # with 2**32 choices is pretty low (< 1% even if we spin up 9000 slaves).
  MYSQL_PWD="$password" mysql --host "$host" --port "$port" --user "$user" --ssl --execute "
    CREATE USER '$MYSQL_REPLICATION_USERNAME'@'$MYSQL_REPLICATION_HOST' IDENTIFIED BY '$MYSQL_REPLICATION_PASSPHRASE';
    GRANT REPLICATION SLAVE ON *.* TO '$MYSQL_REPLICATION_USERNAME'@'localhost';
    GRANT REPLICATION SLAVE ON *.* TO '$MYSQL_REPLICATION_USERNAME'@'$MYSQL_REPLICATION_HOST' REQUIRE SSL;
  "

  # Send our replication data
  echo "MYSQL_REPLICATION_SLAVE_SERVER_ID='${MYSQL_REPLICATION_SLAVE_SERVER_ID}'"
  echo "MYSQL_REPLICATION_MASTER_ROOT_URL='${2}'"
  echo "MYSQL_REPLICATION_MASTER_REPL_URL='mysql://${MYSQL_REPLICATION_USERNAME}:${MYSQL_REPLICATION_PASSPHRASE}@${host}:${port:-3306}/${database}'"

elif [[ "$1" == "--initialize-follower" ]]; then
  # Expected configuration in the environment (these values are provided by --activate-leader)
  # - MYSQL_REPLICATION_SLAVE_SERVER_ID
  # - MYSQL_REPLICATION_MASTER_ROOT_URL
  # - MYSQL_REPLICATION_MASTER_REPL_URL
  MASTER_DUMPFILE=/tmp/master.dump

  # Create slave configuration
  echo "${MYSQL_REPLICATION_SLAVE_SERVER_ID}" > "${DATA_DIRECTORY}/server-id"

  mysql_initialize_certs
  mysql_initialize_data_dir
  mysql_initialize_conf_dir

  # Now, retrieve data from the master
  # Note that this will fail if binary logging is not enabled on the master (because we use --master-data, which
  # is expected to include the binary log position), which is good.

  # TODO - Do we want to enable --single-transaction? This would be preferable because right now
  # we'll acquire locks that will slow down any currently running application (which is bad).
  # If we use --single-transaction, that won't be the case, but:
  # - It only works properly with InnoDB tables, but MySQL won't enforce it.
  # - There can't be any data definition operations (e.g. ALTER TABLE happening at the same time), but
  #   MySQL won't enforce it.
  parse_url "${MYSQL_REPLICATION_MASTER_ROOT_URL}"
  MYSQL_PWD="$password" mysqldump --all-databases --master-data --host "$host" --port "$port" --user "$user" --ssl-cipher="${SSL_CIPHER}" > "${MASTER_DUMPFILE}"


  # Launch MySQL, load the data in, then start the slave.
  # The slave will restart automatically next time MySQL starts up.
  mysql_start_background

  # Change MASTER_PORT *must* be run before loading the dump, otherwise MySQL
  # will assume the master has changed and reset the positions set by the dump...
  # http://dev.mysql.com/doc/refman/5.6/en/change-master-to.html
  parse_url "${MYSQL_REPLICATION_MASTER_REPL_URL}"
  mysql -e "CHANGE MASTER TO
    MASTER_HOST = '${host}',
    MASTER_PORT = ${port},
    MASTER_USER = '${user}',
    MASTER_PASSWORD = '${password}',
    MASTER_SSL = 1,
    MASTER_SSL_CIPHER = '${SSL_CIPHER}';"

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
  MYSQL_PWD="$password" mysql --host="$host" --port="$port" --user="$user" "$database" --ssl-cipher="${SSL_CIPHER}" "$@"

elif [[ "$1" == "--dump" ]]; then
  [ -z "$2" ] && echo "docker run aptible/mysql --dump mysql://... > dump.sql" && exit
  parse_url "$2"
  # If the file /dump-output exists, write output there. Otherwise, use stdout.
  [ -e /dump-output ] && exec 3>/dump-output || exec 3>&1
  MYSQL_PWD="$password" mysqldump --host="$host" --port="$port" --user="$user" "$database" --ssl-cipher="${SSL_CIPHER}" >&3

elif [[ "$1" == "--restore" ]]; then
  [ -z "$2" ] && echo "docker run -i aptible/mysql --restore mysql://... < dump.sql" && exit
  parse_url "$2"
  # If the file /restore-input exists, read input there. Otherwise, use stdin.
  [ -e /restore-input ] && exec 3</restore-input || exec 3<&0
  MYSQL_PWD="$password" mysql --host="$host" --port="$port" --user="$user" "$database" --ssl-cipher="${SSL_CIPHER}" <&3

elif [[ "$1" == "--readonly" ]]; then
  echo "Starting MySQL in read-only mode..."
  mysql_initialize_conf_dir
  exec mysqld_safe --read-only --ssl # TODO - Function?

else
  mysql_initialize_conf_dir
  exec mysqld_safe --ssl
fi
