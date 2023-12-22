#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/test_helper.sh"

get_session_protocol() {
  run-database.sh --client "mysql://root@localhost/db" "$@" \
    -Ee "SHOW SESSION STATUS LIKE 'Ssl_version';" | grep Value | awk '{print $2}'
}

@test "It should be configured to allow connections using TLS1.2 and TLS1.3" {
  tls_versions="$(run-database.sh --client 'mysql://root@localhost/db' \
    -Ee "SHOW GLOBAL VARIABLES LIKE 'tls_version';" | grep Value | awk '{print $2}')"
  [[ "$tls_versions" == "TLSv1.2,TLSv1.3" ]]
}

@test "It should allow connections using TLS1.2" {
  tls_version="$(get_session_protocol --tls-version=TLSv1.2)"
  [[ "$tls_version" == "TLSv1.2" ]]
}

@test "It should allow connections using TLS1.3" {
  tls_version="$(get_session_protocol --tls-version=TLSv1.3)"
  [[ "$tls_version" == "TLSv1.3" ]]
}

@test "It should allow connections over SSL" {
  cipher=$(run-database.sh --client "mysql://root@localhost/db" -Ee "show status like 'Ssl_cipher'" | grep Value | awk '{ print $2 }')
  [[ "$cipher" == "TLS_AES_256_GCM_SHA384" ]]
}