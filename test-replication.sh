#!/bin/bash
set -o errexit
set -o nounset

IMG="$1"

SOURCE_CONTAINER="mysql-source"
SOURCE_DATA_CONTAINER="${SOURCE_CONTAINER}-data"
REPLICA_CONTAINER="mysql-replica"
REPLICA_DATA_CONTAINER="${REPLICA_CONTAINER}-data"
CHAINED_REPLICA_CONTAINER="chained-mysql-replica"
CHAINED_REPLICA_DATA_CONTAINER="${CHAINED_REPLICA_CONTAINER}-data"

function cleanup {
  echo "Cleaning up"
  docker rm -f "$SOURCE_CONTAINER" "$SOURCE_DATA_CONTAINER" "$REPLICA_CONTAINER" "$REPLICA_DATA_CONTAINER" \
               "$CHAINED_REPLICA_CONTAINER" "$CHAINED_REPLICA_DATA_CONTAINER" || true
}

trap cleanup EXIT
cleanup

USER=testuser
PASSPHRASE=testpass
DATABASE=testdb


echo "Initializing data containers"

docker create --name "$SOURCE_DATA_CONTAINER" "$IMG"
docker create --name "$REPLICA_DATA_CONTAINER" "$IMG"
docker create --name "$CHAINED_REPLICA_DATA_CONTAINER" "$IMG"


echo "Initializing replication source"

SOURCE_PORT=33061  # Test with a nonstandard port

docker run -it --rm \
  -e USERNAME="$USER" -e PASSPHRASE="$PASSPHRASE" -e DATABASE="$DATABASE" \
  --volumes-from "$SOURCE_DATA_CONTAINER" \
  "$IMG" --initialize

docker run --rm -d --name="$SOURCE_CONTAINER" \
  -e "PORT=${SOURCE_PORT}" \
  --volumes-from "$SOURCE_DATA_CONTAINER" \
  "$IMG"


until docker exec -it "$SOURCE_CONTAINER" mysqladmin ping; do sleep 0.1; done

SOURCE_IP="$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' "$SOURCE_CONTAINER")"
SOURCE_USER_URL="mysql://$USER:$PASSPHRASE@$SOURCE_IP:$SOURCE_PORT/$DATABASE"
SOURCE_ROOT_URL="mysql://root:$PASSPHRASE@$SOURCE_IP:$SOURCE_PORT/$DATABASE"


echo "Creating test_before table"

docker run -it --rm "$IMG" --client "$SOURCE_USER_URL" -e "CREATE TABLE test_before (col TEXT);"
docker run -it --rm "$IMG" --client "$SOURCE_USER_URL" -e "INSERT INTO test_before VALUES ('TEST DATA BEFORE');"

# If a database has a view of a view, restoring a dump prepared by `mysqldump --all-database` will fail :
#   ERROR 1449 (HY000) at line 1031: The user specified as a definer (‘root’@‘%’) does not exist
# run-database.sh  --initialize from has been updated to handle this :
docker run -it --rm "$IMG" --client "$SOURCE_ROOT_URL" -e "CREATE DEFINER='root'@'%' SQL SECURITY DEFINER VIEW view1 AS SELECT * FROM test_before;"
docker run -it --rm "$IMG" --client "$SOURCE_ROOT_URL" -e "CREATE DEFINER='root'@'%' SQL SECURITY DEFINER VIEW view2 AS SELECT * FROM view1"

echo "Initializing replica"
REPLICA_PORT=33062

docker run -it --rm \
  --volumes-from "$REPLICA_DATA_CONTAINER" \
  "$IMG" --initialize-from "$SOURCE_USER_URL"   # Use the user URL, but --initialize-from will use root instead

echo "No binlog file on the replica contains statements loaded from the dump"
# MySQL 5.6 / 5.7 compatibility
if [[ "$MYSQL_VERSION" = "5.6" ]]; then
  BINGLOG_INDEX="000003"
else
  BINGLOG_INDEX="000002"
fi

(! docker run -it --rm \
  --volumes-from "$REPLICA_DATA_CONTAINER" \
  --entrypoint mysqlbinlog "$IMG" "/var/db/mysql-bin.${BINGLOG_INDEX}" \
  | grep 'CREATE TABLE `test_before`' )

# Run the replica database
docker run --rm -d --name "$REPLICA_CONTAINER" \
  -e "PORT=${REPLICA_PORT}" \
  --volumes-from "$REPLICA_DATA_CONTAINER" \
  "$IMG"

REPLICA_IP="$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' "$REPLICA_CONTAINER")"
REPLICA_ROOT_URL="mysql://root:$PASSPHRASE@$REPLICA_IP:$REPLICA_PORT/$DATABASE"
REPLICA_USER_URL="mysql://$USER:$PASSPHRASE@$REPLICA_IP:$REPLICA_PORT/$DATABASE"

until docker exec -it "$REPLICA_CONTAINER" mysqladmin ping; do sleep 0.1; done
docker run -it --rm "$IMG" --client "$REPLICA_ROOT_URL" -e "SHOW SLAVE STATUS \G"

echo "Initializing chained replication replica"
CHAINED_REPLICA_PORT=33063

docker run -it --rm \
  --volumes-from "$CHAINED_REPLICA_DATA_CONTAINER" \
  "$IMG" --initialize-from "$REPLICA_USER_URL"   # Use the user URL, but --initialize-from will use root instead

docker run --rm -d --name "$CHAINED_REPLICA_CONTAINER" \
  -e "PORT=${CHAINED_REPLICA_PORT}" \
  --volumes-from "$CHAINED_REPLICA_DATA_CONTAINER" \
  "$IMG"

CHAINED_REPLICA_IP="$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' "$CHAINED_REPLICA_CONTAINER")"
CHAINED_REPLICA_ROOT_URL="mysql://root:$PASSPHRASE@$CHAINED_REPLICA_IP:$CHAINED_REPLICA_PORT/$DATABASE"
CHAINED_REPLICA_USER_URL="mysql://$USER:$PASSPHRASE@$CHAINED_REPLICA_IP:$CHAINED_REPLICA_PORT/$DATABASE"


until docker exec -it "$CHAINED_REPLICA_CONTAINER" mysqladmin ping; do sleep 0.1; done
docker run -it --rm "$IMG" --client "$CHAINED_REPLICA_ROOT_URL" -e "SHOW SLAVE STATUS \G"


# Create a test table now that replication has started
docker run -it --rm "$IMG" --client "$SOURCE_USER_URL" -e "CREATE TABLE test_after (col TEXT);"
docker run -it --rm "$IMG" --client "$SOURCE_USER_URL" -e "INSERT INTO test_after VALUES ('TEST DATA AFTER');"

# Give replication time it needs to catch up (should usually be essentially instantaneous, but who knows,
# some CI systems might run slower.
until docker run --rm "$IMG" --client "$CHAINED_REPLICA_ROOT_URL" -e "SHOW SLAVE STATUS \G" | grep "Waiting for master to send event"; do sleep 0.1; done

# Check that data is present in both tables
docker run -it --rm "$IMG" --client "$CHAINED_REPLICA_USER_URL" -e 'SELECT * FROM test_before;' | grep 'TEST DATA BEFORE'
docker run -it --rm "$IMG" --client "$CHAINED_REPLICA_USER_URL" -e 'SELECT * FROM test_after;' | grep 'TEST DATA AFTER'

# Confirm binlog files should be named "mysql-bin.NNNNNN"
docker exec -it "$CHAINED_REPLICA_CONTAINER" grep "log-bin = mysql-bin" "/etc/mysql/conf.d/00-replication.cnf"
