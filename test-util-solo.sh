#!/bin/bash
MYSQL_CONTAINER="mysql"
DATA_CONTAINER="${MYSQL_CONTAINER}-data"

cleanup_solo() {
  echo "Cleaning up"
  docker rm -f "$MYSQL_CONTAINER" "$DATA_CONTAINER" >/dev/null 2>&1 || true
}

bootstrap_solo() {
  trap "quietly cleanup_solo" EXIT
  quietly cleanup_solo

  echo "Creating data container"
  quietly docker create --name "$DATA_CONTAINER" "$IMG"

  echo "Initializing MySQL"
  quietly docker run -it --rm \
    -e USERNAME=user -e PASSPHRASE=pass -e DATABASE=db \
    --volumes-from "$DATA_CONTAINER" \
    "$IMG" --initialize

  echo "Starting MySQL"
  quietly docker run -d --name="$MYSQL_CONTAINER" \
    --volumes-from "$DATA_CONTAINER" \
    "$IMG"

  echo "Waiting for MySQL"
  quietly wait_for_mysql
}
