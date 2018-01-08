#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/test_helper.sh"

setup() {
  initialize_mysql
}

teardown() {
  stop_mysql
}

@test "It should autotune for a 512MB container" {
  APTIBLE_CONTAINER_SIZE=512 run_server
  run-database.sh --client "mysql://root@localhost/db" -Ee "SELECT @@innodb_buffer_pool_size/1024/1024;" | grep 306
}

@test "It should autotune for a 1GB container" {
  APTIBLE_CONTAINER_SIZE=1024 run_server
  run-database.sh --client "mysql://root@localhost/db" \
    -Ee "SELECT @@innodb_buffer_pool_size/1024/1024;" | grep 612
}

@test "It should autotune for a 2GB container" {
  APTIBLE_CONTAINER_SIZE=2048 run_server
  run-database.sh --client "mysql://root@localhost/db" \
    -Ee "SELECT @@innodb_buffer_pool_size/1024/1024;" | grep 1224
}

@test "It should autotune for a 4GB container" {
  APTIBLE_CONTAINER_SIZE=4096 run_server
  run-database.sh --client "mysql://root@localhost/db" \
    -Ee "SELECT @@innodb_buffer_pool_size/1024/1024;" | grep 2448
}
