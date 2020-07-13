#!/bin/bash
set -o errexit
set -o nounset

IMG="$1"

MASTER_CONTAINER="mysql-master"
MASTER_DATA_CONTAINER="${MASTER_CONTAINER}-data"
SLAVE_CONTAINER="mysql-slave"
SLAVE_DATA_CONTAINER="${SLAVE_CONTAINER}-data"
CHAINED_SLAVE_CONTAINER="chained-mysql-slave"
CHAINED_SLAVE_DATA_CONTAINER="${CHAINED_SLAVE_CONTAINER}-data"

function cleanup {
  echo "Cleaning up"
  docker rm -f "$MASTER_CONTAINER" "$MASTER_DATA_CONTAINER" "$SLAVE_CONTAINER" "$SLAVE_DATA_CONTAINER" \
               "$CHAINED_SLAVE_CONTAINER" "$CHAINED_SLAVE_DATA_CONTAINER" || true
}

trap cleanup EXIT
cleanup

USER=testuser
PASSPHRASE=testpass
DATABASE=testdb


echo "Initializing data containers"

docker create --name "$MASTER_DATA_CONTAINER" "$IMG"
docker create --name "$SLAVE_DATA_CONTAINER" "$IMG"
docker create --name "$CHAINED_SLAVE_DATA_CONTAINER" "$IMG"


echo "Initializing replication master"

MASTER_PORT=33061  # Test with a nonstandard port

docker run -it --rm \
  -e USERNAME="$USER" -e PASSPHRASE="$PASSPHRASE" -e DATABASE="$DATABASE" \
  --volumes-from "$MASTER_DATA_CONTAINER" \
  "$IMG" --initialize

docker run --rm -d --name="$MASTER_CONTAINER" \
  -e "PORT=${MASTER_PORT}" \
  --volumes-from "$MASTER_DATA_CONTAINER" \
  "$IMG"


until docker exec -it "$MASTER_CONTAINER" mysqladmin ping; do sleep 0.1; done

MASTER_IP="$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' "$MASTER_CONTAINER")"
MASTER_USER_URL="mysql://$USER:$PASSPHRASE@$MASTER_IP:$MASTER_PORT/$DATABASE"
MASTER_ROOT_URL="mysql://root:$PASSPHRASE@$MASTER_IP:$MASTER_PORT/$DATABASE"


echo "Creating test_before table"

docker run -it --rm "$IMG" --client "$MASTER_USER_URL" -e "CREATE TABLE test_before (col TEXT);"
docker run -it --rm "$IMG" --client "$MASTER_USER_URL" -e "INSERT INTO test_before VALUES ('TEST DATA BEFORE');"

# If a database has a view of a view, restoring a dump prepared by `mysqldump --all-database` will fail :
#   ERROR 1449 (HY000) at line 1031: The user specified as a definer (‘root’@‘%’) does not exist
# run-database.sh  --initialize from has been updated to handle this :
docker run -it --rm "$IMG" --client "$MASTER_ROOT_URL" -e "CREATE DEFINER='root'@'%' SQL SECURITY DEFINER VIEW view1 AS SELECT * FROM test_before;"
docker run -it --rm "$IMG" --client "$MASTER_ROOT_URL" -e "CREATE DEFINER='root'@'%' SQL SECURITY DEFINER VIEW view2 AS SELECT * FROM view1"

echo "Initializing replication slave"
SLAVE_PORT=33062

docker run -it --rm \
  --volumes-from "$SLAVE_DATA_CONTAINER" \
  "$IMG" --initialize-from "$MASTER_USER_URL"   # Use the user URL, but --initialize-from will use root instead

echo "No binlog file on the replica contains statements loaded from the dump"
# MySQL 5.6 / 5.7 compatibility
if [[ "$MYSQL_VERSION" = "5.6" ]]; then
  BINGLOG_INDEX="000003"
else
  BINGLOG_INDEX="000002"
fi

(! docker run -it --rm \
  --volumes-from "$SLAVE_DATA_CONTAINER" \
  --entrypoint mysqlbinlog "$IMG" "/var/db/mysql-bin.${BINGLOG_INDEX}" \
  | grep 'CREATE TABLE `test_before`' )

# Run the slave database
docker run --rm -d --name "$SLAVE_CONTAINER" \
  -e "PORT=${SLAVE_PORT}" \
  --volumes-from "$SLAVE_DATA_CONTAINER" \
  "$IMG"

SLAVE_IP="$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' "$SLAVE_CONTAINER")"
SLAVE_ROOT_URL="mysql://root:$PASSPHRASE@$SLAVE_IP:$SLAVE_PORT/$DATABASE"
SLAVE_USER_URL="mysql://$USER:$PASSPHRASE@$SLAVE_IP:$SLAVE_PORT/$DATABASE"

until docker exec -it "$SLAVE_CONTAINER" mysqladmin ping; do sleep 0.1; done
docker run -it --rm "$IMG" --client "$SLAVE_ROOT_URL" -e "SHOW SLAVE STATUS \G"

echo "Initializing chained replication slave"
CHAINED_SLAVE_PORT=33063

docker run -it --rm \
  --volumes-from "$CHAINED_SLAVE_DATA_CONTAINER" \
  "$IMG" --initialize-from "$SLAVE_USER_URL"   # Use the user URL, but --initialize-from will use root instead

docker run --rm -d --name "$CHAINED_SLAVE_CONTAINER" \
  -e "PORT=${CHAINED_SLAVE_PORT}" \
  --volumes-from "$CHAINED_SLAVE_DATA_CONTAINER" \
  "$IMG"

CHAINED_SLAVE_IP="$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' "$CHAINED_SLAVE_CONTAINER")"
CHAINED_SLAVE_ROOT_URL="mysql://root:$PASSPHRASE@$CHAINED_SLAVE_IP:$CHAINED_SLAVE_PORT/$DATABASE"
CHAINED_SLAVE_USER_URL="mysql://$USER:$PASSPHRASE@$CHAINED_SLAVE_IP:$CHAINED_SLAVE_PORT/$DATABASE"


until docker exec -it "$CHAINED_SLAVE_CONTAINER" mysqladmin ping; do sleep 0.1; done
docker run -it --rm "$IMG" --client "$CHAINED_SLAVE_ROOT_URL" -e "SHOW SLAVE STATUS \G"


# Create a test table now that replication has started
docker run -it --rm "$IMG" --client "$MASTER_USER_URL" -e "CREATE TABLE test_after (col TEXT);"
docker run -it --rm "$IMG" --client "$MASTER_USER_URL" -e "INSERT INTO test_after VALUES ('TEST DATA AFTER');"

# Give replication time it needs to catch up (should usually be essentially instantaneous, but who knows,
# some CI systems might run slower.
until docker run --rm "$IMG" --client "$CHAINED_SLAVE_ROOT_URL" -e "SHOW SLAVE STATUS \G" | grep "Waiting for master to send event"; do sleep 0.1; done

# Check that data is present in both tables
docker run -it --rm "$IMG" --client "$CHAINED_SLAVE_USER_URL" -e 'SELECT * FROM test_before;' | grep 'TEST DATA BEFORE'
docker run -it --rm "$IMG" --client "$CHAINED_SLAVE_USER_URL" -e 'SELECT * FROM test_after;' | grep 'TEST DATA AFTER'

# Confirm binlog files should be named "mysql-bin.NNNNNN"
docker exec -it "$CHAINED_SLAVE_CONTAINER" grep "log-bin = mysql-bin" "/etc/mysql/conf.d/00-replication.cnf"
