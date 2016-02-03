#!/bin/bash
set -o errexit
set -o nounset


IMG="$REGISTRY/$REPOSITORY:$TAG"

MASTER_CONTAINER="mysql-master"
MASTER_DATA_CONTAINER="${MASTER_CONTAINER}-data"
SLAVE_CONTAINER="mysql-slave"
SLAVE_DATA_CONTAINER="${SLAVE_CONTAINER}-data"

function cleanup {
  echo "Cleaning up"
  docker rm -f "$MASTER_CONTAINER" "$MASTER_DATA_CONTAINER" "$SLAVE_CONTAINER" "$SLAVE_DATA_CONTAINER" || true
}

trap cleanup EXIT
cleanup

USER=testuser
PASSPHRASE=testpass
DATABASE=testdb


echo "Initializing data containers"

docker create --name "$MASTER_DATA_CONTAINER" "$IMG"
docker create --name "$SLAVE_DATA_CONTAINER" "$IMG"


echo "Initializing replication master"

MASTER_PORT=33061  # Test with a nonstandard port

docker run -it --rm \
  -e USERNAME="$USER" -e PASSPHRASE="$PASSPHRASE" -e DATABASE="$DATABASE" \
  --volumes-from "$MASTER_DATA_CONTAINER" \
  "$IMG" --initialize

docker run -d --name="$MASTER_CONTAINER" \
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


echo "Initializing replication slave"
SLAVE_PORT=33062

docker run -it --rm \
  --volumes-from "$SLAVE_DATA_CONTAINER" \
  "$IMG" --initialize-from "$MASTER_USER_URL"   # Use the user URL, but --initialize-from will use root instead

docker run -d --name "$SLAVE_CONTAINER" \
  -e "PORT=${SLAVE_PORT}" \
  --volumes-from "$SLAVE_DATA_CONTAINER" \
  "$IMG"


SLAVE_IP="$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' "$SLAVE_CONTAINER")"
SLAVE_ROOT_URL="mysql://root:$PASSPHRASE@$SLAVE_IP:$SLAVE_PORT/$DATABASE"
SLAVE_USER_URL="mysql://$USER:$PASSPHRASE@$SLAVE_IP:$SLAVE_PORT/$DATABASE"


until docker exec -it "$SLAVE_CONTAINER" mysqladmin ping; do sleep 0.1; done
docker run -it --rm "$IMG" --client "$SLAVE_ROOT_URL" -e "SHOW SLAVE STATUS \G"


# Create a test table now that replication has started
docker run -it --rm "$IMG" --client "$MASTER_USER_URL" -e "CREATE TABLE test_after (col TEXT);"
docker run -it --rm "$IMG" --client "$MASTER_USER_URL" -e "INSERT INTO test_after VALUES ('TEST DATA AFTER');"

# Give replication time it needs to catch up (should usually be essentially instantaneous, but who knows,
# some CI systems might run slower.
until docker run --rm "$IMG" --client "$SLAVE_ROOT_URL" -e "SHOW SLAVE STATUS \G" | grep "Waiting for master to send event"; do sleep 0.1; done

# Check that data is present in both tables
docker run -it --rm "$IMG" --client "$SLAVE_USER_URL" -e 'SELECT * FROM test_before;' | grep 'TEST DATA BEFORE'
docker run -it --rm "$IMG" --client "$SLAVE_USER_URL" -e 'SELECT * FROM test_after;' | grep 'TEST DATA AFTER'

echo "Test OK!"
