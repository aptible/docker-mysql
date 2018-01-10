#!/bin/bash

wait_for() {
  local timeout="$1"
  shift

  local attempts="$((timeout * 10))"

  for i in $(seq 1 "$attempts"); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi

    echo "[$i] ${*} has not succeeded yet..." >&2
    sleep 0.1
  done

  return 1
}

wait_for_timeout() {
  ! wait_for "$@"
}

wait_for_mysql() {
  if wait_for 5 docker exec "$MYSQL_CONTAINER" mysqladmin ping; then
    return 0
  else
    echo "MySQL never came online" >&2
    docker logs "$MYSQL_CONTAINER" >&2
    return 1
  fi
}

quietly() {
  local out err

  out="$(mktemp)"
  err="$(mktemp)"

  if "$@" > "$out" 2> "$err"; then
    rm "$out" "$err"
    return 0;
  else
    local status="$?"
    echo    "COMMAND FAILED:" "$@"
    echo    "STATUS:         ${status}"
    sed 's/^/STDOUT:         /' < "$out"
    sed 's/^/STDERR:         /' < "$err"
    return "$status"
  fi
}
