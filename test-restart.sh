#!/bin/bash
set -o errexit
set -o nounset

IMG="$1"

MYSQL_CONTAINER="mysql"
DATA_CONTAINER="${MYSQL_CONTAINER}-data"

function cleanup {
  echo "Cleaning up"
  docker rm -f "$MYSQL_CONTAINER" "$DATA_CONTAINER" >/dev/null 2>&1 || true
}

function wait_for_mysql {
  for _ in $(seq 1 1000); do
    if docker exec -it "$MYSQL_CONTAINER" mysqladmin ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  echo "MySQL never came online"
  docker logs "$MYSQL_CONTAINER"
  return 1
}

trap cleanup EXIT
cleanup

echo "Creating data container"
docker create --name "$DATA_CONTAINER" "$IMG"

echo "Starting DB"
docker run -it --rm \
  -e USERNAME=user -e PASSPHRASE=pass -e DATABASE=db \
  --volumes-from "$DATA_CONTAINER" \
  "$IMG" --initialize \
  >/dev/null 2>&1

docker run -d --name="$MYSQL_CONTAINER" \
  --volumes-from "$DATA_CONTAINER" \
  "$IMG"

echo "Waiting for DB to come online"
wait_for_mysql

echo "Verifying MySQL shutdown message isn't present"
docker logs "$MYSQL_CONTAINER" 2>&1 | grep -qv "Shutdown complete"

echo "Restarting DB container"
date
docker top "$MYSQL_CONTAINER"
docker restart -t 10 "$MYSQL_CONTAINER"

echo "Waiting for DB to come back online"
wait_for_mysql

echo "DB came back online; checking for clean shutdown"
date
docker logs "$MYSQL_CONTAINER" 2>&1 | grep "Shutdown complete"
docker logs "$MYSQL_CONTAINER" 2>&1 | grep -qv "Crash recovery finished"

echo "Attempting unclean shutdown"
docker kill -s KILL "$MYSQL_CONTAINER"
docker start "$MYSQL_CONTAINER"


echo "Waiting for DB to come back online"
wait_for_mysql

docker logs "$MYSQL_CONTAINER" 2>&1 | grep "Crash recovery finished"
