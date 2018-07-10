#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/test_helper.sh"

get_session_protocol() {
  run-database.sh --client "mysql://root@localhost/db" "$@" \
    -Ee "SHOW SESSION STATUS LIKE 'Ssl_version';" | grep Value | awk '{print $2}'
}

@test "It should be configured to allow connections using TLS1.0 and TLS1.1" {
  tls_versions="$(run-database.sh --client 'mysql://root@localhost/db' \
    -Ee "SHOW GLOBAL VARIABLES LIKE 'tls_version';" | grep Value | awk '{print $2}')"
  [[ "$tls_versions" == "TLSv1,TLSv1.1" ]]
}

@test "It should allow connections using TLS1.0" {
  tls_version="$(get_session_protocol --tls-version=TLSv1)"
  [[ "$tls_version" == "TLSv1" ]]
}

@test "It should allow connections using TLS1.1" {
  tls_version="$(get_session_protocol --tls-version=TLSv1.1)"
  [[ "$tls_version" == "TLSv1.1" ]]
}

@test "It should disallow connections using TLS1.2" {
  tls_version="$(get_session_protocol --tls-version=TLSv1.2)"
  ! [[ "$tls_version" == "TLSv1.2" ]]
}
