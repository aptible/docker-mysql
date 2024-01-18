#!/usr/bin/env bats

source "${BATS_TEST_DIRNAME}/test_helper.sh"

@test "It defaults connections using TLS1.2" {
  tls_version="$(run-database.sh --client 'mysql://root@localhost/db' \
    -Ee "SHOW SESSION STATUS LIKE 'Ssl_version';" | grep Value | awk '{ print $2 }')"
  [[ "$tls_version" == "TLSv1.2" ]]
}

@test "It should allow connections over SSL" {
  cipher=$(run-database.sh --client "mysql://root@localhost/db" -Ee "show status like 'Ssl_cipher'" | grep Value | awk '{ print $2 }')
  [[ "$cipher" == "DHE-RSA-AES256-SHA256" ]]
}