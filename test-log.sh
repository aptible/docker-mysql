#!/bin/bash
set -o errexit
set -o nounset

if [[ -n "${TRAVIS:-}" ]]; then
  echo "Skip: this test does not work on Travis"
  exit 0
fi

. test-util.sh
. test-util-solo.sh

IMG="$1"

function grep_mysql_logs {
  local needle="$1"
  docker logs "$MYSQL_CONTAINER" 2>&1 | grep -qE "$needle"
}

CANARY='hello from the log file'

bootstrap_solo

echo "Verify no canary is logged"
quietly docker exec "$MYSQL_CONTAINER" mysql db -e "SELECT '$CANARY';"
quietly wait_for_timeout 2 grep_mysql_logs "general.*$CANARY"

echo "Verify canary is logged when general_log = 1"
quietly docker exec "$MYSQL_CONTAINER" mysql db -e "SET GLOBAL general_log = 1;"
quietly docker exec "$MYSQL_CONTAINER" mysql db -e "SELECT '$CANARY';"
quietly wait_for 2 grep_mysql_logs "general.*$CANARY"

echo "Verify no SLEEP is logged"
quietly docker exec "$MYSQL_CONTAINER" mysql db -e "SET GLOBAL long_query_time = 1;"
quietly docker exec "$MYSQL_CONTAINER" mysql db -e "SELECT SLEEP(3);"
quietly wait_for_timeout 2 grep_mysql_logs "slow.*SLEEP"

echo "Verify SLEEP is logged when slow_query_log = 1"
quietly docker exec "$MYSQL_CONTAINER" mysql db -e "SET GLOBAL slow_query_log = 1;"
quietly docker exec "$MYSQL_CONTAINER" mysql db -e "SELECT SLEEP(3);"
quietly wait_for 2 grep_mysql_logs "slow.*SLEEP"
