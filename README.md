# ![](https://gravatar.com/avatar/11d3bc4c3163e3d238d558d5c9d98efe?s=64) aptible/mysql

[![Docker Repository on Quay.io](https://quay.io/repository/aptible/mysql/status)](https://quay.io/repository/aptible/mysql)
[![Build Status](https://travis-ci.org/aptible/docker-mysql.svg?branch=master)](https://travis-ci.org/aptible/docker-mysql)

[![](http://dockeri.co/image/aptible/mysql)](https://registry.hub.docker.com/u/aptible/mysql/)

MySQL Community Server on Docker.

## Installation and Usage

    docker pull quay.io/aptible/mysql

This is an image conforming to the [Aptible database specification](https://support.aptible.com/topics/paas/deploy-custom-database/). To run a server for development purposes, execute

    docker create --name data quay.io/aptible/mysql
    docker run --volumes-from data -e USERNAME=aptible -e PASSPHRASE=pass -e DATABASE=db quay.io/aptible/mysql --initialize
    docker run --volumes-from data -P quay.io/aptible/mysql

The first command sets up a data container named `data` which will hold the configuration and data for the database. The second command creates a MySQL instance with a username, passphrase and database name of your choice. The third command starts the database server.

### SSL

The MySQL server is configured to require SSL for any TCP connection that
authenticates as the `USERNAME` that the database was initialized with. The SSL
connection relies on a self-signed certficate that is generated when
`--initialize` is called. Because it's often difficult to force an SSL
connection from some clients, we also create another user with a `-nossl` suffix
that allows but does not require SSL. For example, if you pass
`USERNAME=aptible` to the database `--initialize` call, an `aptible` user is
created that requires SSL over TCP and an `aptible-nossl` user is created that
does not require SSL over TCP.

When you connect via the `--client` flag using the Docker image, SSL is forced.
Connecting from other clients or from the `mysql` command line utility involves
setting various
[ssl flags](https://dev.mysql.com/doc/refman/5.6/en/ssl-options.html) and it's
sometimes unclear which are mandatory and what configuration is implied by
different combinations of flags. The simplest way to force SSL from a client is
to set the `ssl-cipher` parameter. This Docker image supports
`DHE-RSA-AES256-SHA` and `AES128-SHA`.

When using an untested client to connect, you should always verify that the
connection parameters you've supplied forces an SSL connection by inspecting
the session's `Ssl_cipher` status variable, for example:

```
mysql> show status like 'Ssl_cipher';
+---------------+--------------------+
| Variable_name | Value              |
+---------------+--------------------+
| Ssl_cipher    | DHE-RSA-AES256-SHA |
+---------------+--------------------+
1 row in set (0.02 sec)
```

This status variable is non-empty exactly when SSL is enabled for the session.

## Available Tags

* `latest`: Currently MySQL MySQL 8.0.15
* `8.0`: MySQL 8.0.15
* `5.7`: MySQL 5.7.25
* `5.6`: MySQL 5.6.43

## Tests

Tests are run as part of the `Dockerfile` build. To execute them separately within a container, run:

    bats test

## Deployment

To push the Docker image to Quay, run the following command:

    make release

## Continuous Integration

Images are built and pushed to Docker Hub on every deploy. Because Quay currently only supports build triggers where the Docker tag name exactly matches a GitHub branch/tag name, we must run the following script to synchronize all our remote branches after a merge to master:

    make sync-branches

## Copyright and License

MIT License, see [LICENSE](LICENSE.md) for details.

Copyright (c) 2015 [Aptible](https://www.aptible.com) and contributors.

[<img src="https://s.gravatar.com/avatar/f7790b867ae619ae0496460aa28c5861?s=60" style="border-radius: 50%;" alt="@fancyremarker" />](https://github.com/fancyremarker)
