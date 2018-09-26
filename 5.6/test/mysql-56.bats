#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/test_helper.sh"

@test "It should allow connections using TLS1.0" {
  tls_version="$(run-database.sh --client 'mysql://root@localhost/db' \
    -Ee "SHOW SESSION STATUS LIKE 'Ssl_version';" | grep Value | awk '{ print $2 }')"
  [[ "$tls_version" == "TLSv1" ]]
}
