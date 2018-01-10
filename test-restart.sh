#!/bin/bash
set -o errexit
set -o nounset

. test-util.sh
. test-util-solo.sh

IMG="$1"

bootstrap_solo

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
