FROM quay.io/aptible/debian:wheezy

# cf. docker-library/mysql: explicitly create the user so uid and gid are consistent.
RUN groupadd -r mysql && useradd -r -g mysql mysql

ENV MYSQL_VERSION 5.7
ENV MYSQL_PACKAGE_VERSION 5.7.11-1debian7

ADD 5.7/templates/etc/apt/sources.list.d /etc/apt/sources.list.d

RUN apt-key adv --keyserver pool.sks-keyservers.net --recv-keys 5072E1F5 && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        faketime \
        netcat \
        perl \
        procps \
        "mysql-server=${MYSQL_PACKAGE_VERSION}" \
        "mysql-client=${MYSQL_PACKAGE_VERSION}" \
        && \
    rm -rf /var/lib/apt/lists/*


ENV CONF_DIRECTORY /etc/mysql
RUN rm -r "$CONF_DIRECTORY"
ADD templates/etc/mysql $CONF_DIRECTORY
ADD 5.7/templates/etc/mysql $CONF_DIRECTORY

ENV DATA_DIRECTORY /var/db
RUN mkdir -p "$DATA_DIRECTORY" && chown -R mysql:mysql "$DATA_DIRECTORY"

ADD bin/run-database.sh /usr/bin/
ADD bin/utilities.sh /usr/bin/

ADD test /tmp/test
RUN bats /tmp/test

VOLUME ["$DATA_DIRECTORY"]
EXPOSE 3306

ENTRYPOINT ["run-database.sh"]
