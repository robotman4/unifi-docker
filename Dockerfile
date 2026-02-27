FROM golang:1.22-bullseye AS permset
WORKDIR /src
RUN git clone https://github.com/jacobalberty/permset.git /src && \
    mkdir -p /out && \
    go build -ldflags "-X main.chownDir=/unifi" -o /out/permset

FROM ubuntu:24.04

LABEL maintainer="Jacob Alberty <jacob.alberty@foundigital.com>"

ARG DEBIAN_FRONTEND=noninteractive

ARG PKGURL=https://dl.ui.com/unifi/10.1.85-n38ayo5w94/unifi_sysvinit_all.deb

ENV BASEDIR=/usr/lib/unifi \
    DATADIR=/unifi/data \
    LOGDIR=/unifi/log \
    CERTDIR=/unifi/cert \
    RUNDIR=/unifi/run \
    ORUNDIR=/var/run/unifi \
    ODATADIR=/var/lib/unifi \
    OLOGDIR=/var/log/unifi \
    CERTNAME=cert.pem \
    CERT_PRIVATE_NAME=privkey.pem \
    CERT_IS_CHAIN=false \
    GOSU_VERSION=1.10 \
    BIND_PRIV=true \
    RUNAS_UID0=true \
    UNIFI_GID=999 \
    UNIFI_UID=999

# Install gosu
# https://github.com/tianon/gosu/blob/master/INSTALL.md
# This should be integrated with the main run because it duplicates a lot of the steps there
# but for now while shoehorning gosu in it is seperate
RUN set -eux; \
	apt-get update; \
	apt-get install -y gosu; \
	rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/unifi \
     /usr/local/unifi/init.d \
     /usr/unifi/init.d \
     /usr/local/docker
COPY docker-entrypoint.sh /usr/local/bin/
COPY docker-healthcheck.sh /usr/local/bin/
COPY docker-build.sh /usr/local/bin/
COPY functions /usr/unifi/functions
COPY import_cert /usr/unifi/init.d/
COPY pre_build /usr/local/docker/pre_build
RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
 && chmod +x /usr/unifi/init.d/import_cert \
 && chmod +x /usr/local/bin/docker-healthcheck.sh \
 && chmod +x /usr/local/bin/docker-build.sh \
 && chmod -R +x /usr/local/docker/pre_build

# Install libssl1.1 (required by mongod 4.x and 5.0 binaries), set up MongoDB repos,
# download/extract migration mongod binaries (4.0–6.0), install MongoDB 7.0 + mongosh system-wide.
# All in one layer to keep the cache-friendly and minimise intermediate layer overhead.
RUN set -eux; \
    apt-get update; \
    apt-get install -y wget gnupg ca-certificates curl; \
    \
    # libssl1.1 — required for mongod 4.x / 5.0 binaries on Ubuntu 24.04
    wget -q http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2_amd64.deb; \
    dpkg -i libssl1.1_1.1.1f-1ubuntu2_amd64.deb; \
    rm libssl1.1_1.1.1f-1ubuntu2_amd64.deb; \
    \
    # MongoDB signing keys (4.0–6.0 binaries via tarball; only 4.4 + 7.0 apt repos needed)
    curl -fsSL https://pgp.mongodb.com/server-4.4.asc \
        | gpg --dearmor -o /usr/share/keyrings/mongodb-server-4.4.gpg; \
    curl -fsSL https://pgp.mongodb.com/server-7.0.asc \
        | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg; \
    \
    # MongoDB apt repositories (only 4.4 focal for dpkg-deb extract, 7.0 jammy for production install)
    echo "deb [ arch=amd64 signed-by=/usr/share/keyrings/mongodb-server-4.4.gpg ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/4.4 multiverse" \
        > /etc/apt/sources.list.d/mongodb-org-4.4.list; \
    echo "deb [ arch=amd64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" \
        > /etc/apt/sources.list.d/mongodb-org-7.0.list; \
    apt-get update; \
    \
    # Download and extract mongod binaries for migration steps (no deps installed)
    mkdir -p /tmp/mongodeb; \
    cd /tmp/mongodeb; \
    \
    # 4.0 — download binary tarball directly (apt repo signing key expired)
    # Also extract the legacy mongo shell — required because mongosh needs wire protocol v8 (MongoDB 4.2+),
    # but mongod 4.0 only supports wire protocol v7.
    mkdir -p /usr/local/mongo/4.0/bin; \
    wget -q "https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-ubuntu1804-4.0.28.tgz" \
        -O /tmp/mongod-4.0.tgz; \
    tar xzf /tmp/mongod-4.0.tgz --strip-components=2 -C /usr/local/mongo/4.0/bin \
        "mongodb-linux-x86_64-ubuntu1804-4.0.28/bin/mongod" \
        "mongodb-linux-x86_64-ubuntu1804-4.0.28/bin/mongo"; \
    chmod +x /usr/local/mongo/4.0/bin/mongod /usr/local/mongo/4.0/bin/mongo; \
    rm /tmp/mongod-4.0.tgz; \
    \
    # 4.2 — download binary tarball directly (focal repo does not carry 4.2.25)
    mkdir -p /usr/local/mongo/4.2/bin; \
    wget -q "https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-ubuntu1804-4.2.25.tgz" \
        -O /tmp/mongod-4.2.tgz; \
    tar xzf /tmp/mongod-4.2.tgz --strip-components=2 -C /usr/local/mongo/4.2/bin \
        "mongodb-linux-x86_64-ubuntu1804-4.2.25/bin/mongod"; \
    chmod +x /usr/local/mongo/4.2/bin/mongod; \
    rm /tmp/mongod-4.2.tgz; \
    \
    apt-get download mongodb-org-server=4.4.30; \
    mkdir -p /usr/local/mongo/4.4/bin; \
    dpkg-deb --extract mongodb-org-server_4.4.30_amd64.deb extract-4.4; \
    cp extract-4.4/usr/bin/mongod /usr/local/mongo/4.4/bin/mongod; \
    chmod +x /usr/local/mongo/4.4/bin/mongod; \
    rm -rf extract-4.4 mongodb-org-server_4.4.30_amd64.deb; \
    \
    # 5.0 — download binary tarball directly (jammy repo does not carry 5.0.31)
    mkdir -p /usr/local/mongo/5.0/bin; \
    wget -q "https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-ubuntu2004-5.0.31.tgz" \
        -O /tmp/mongod-5.0.tgz; \
    tar xzf /tmp/mongod-5.0.tgz --strip-components=2 -C /usr/local/mongo/5.0/bin \
        "mongodb-linux-x86_64-ubuntu2004-5.0.31/bin/mongod"; \
    chmod +x /usr/local/mongo/5.0/bin/mongod; \
    rm /tmp/mongod-5.0.tgz; \
    \
    # 6.0 — download binary tarball directly (jammy repo does not carry 6.0.20)
    mkdir -p /usr/local/mongo/6.0/bin; \
    wget -q "https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-ubuntu2204-6.0.20.tgz" \
        -O /tmp/mongod-6.0.tgz; \
    tar xzf /tmp/mongod-6.0.tgz --strip-components=2 -C /usr/local/mongo/6.0/bin \
        "mongodb-linux-x86_64-ubuntu2204-6.0.20/bin/mongod"; \
    chmod +x /usr/local/mongo/6.0/bin/mongod; \
    rm /tmp/mongod-6.0.tgz; \
    \
    cd /; \
    rm -rf /tmp/mongodeb; \
    \
    # MongoDB 7.0 — system-wide production binary
    apt-get install -y mongodb-org-server; \
    \
    # mongosh — needed for ping checks and FCV commands during migration
    apt-get install -y mongodb-mongosh; \
    \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Push installing openjdk-8-jre first, so that the unifi package doesn't pull in openjdk-7-jre as a dependency? Else uncomment and just go with openjdk-7.
RUN set -ex \
 && mkdir -p /usr/share/man/man1/ \
 && groupadd -r unifi -g $UNIFI_GID \
 && useradd --no-log-init -r -u $UNIFI_UID -g $UNIFI_GID unifi \
 && /usr/local/bin/docker-build.sh "${PKGURL}"

COPY --from=permset /out/permset /usr/local/bin/permset
RUN chown 0.0 /usr/local/bin/permset && \
    chmod +s /usr/local/bin/permset

RUN mkdir -p /unifi && chown unifi:unifi -R /unifi

# Migration and helper scripts
COPY scripts/ /usr/local/unifi/scripts/
RUN chmod +x /usr/local/unifi/scripts/*

# Apply any hotfixes that were included
COPY hotfixes /usr/local/unifi/hotfixes

RUN chmod +x /usr/local/unifi/hotfixes/* && run-parts /usr/local/unifi/hotfixes

VOLUME ["/unifi", "${RUNDIR}"]

EXPOSE 6789/tcp 8080/tcp 8443/tcp 8880/tcp 8843/tcp 3478/udp 10001/udp

WORKDIR /unifi

HEALTHCHECK --start-period=5m CMD /usr/local/bin/docker-healthcheck.sh || exit 1

# execute controller using JSVC like original debian package does
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

CMD ["unifi"]

# execute the conroller directly without using the service
#ENTRYPOINT ["/usr/bin/java", "-Xmx${JVM_MAX_HEAP_SIZE}", "-jar", "/usr/lib/unifi/lib/ace.jar"]
  # See issue #12 on github: probably want to consider how JSVC handled creating multiple processes, issuing the -stop instraction, etc. Not sure if the above ace.jar class gracefully handles TERM signals.
#CMD ["start"]
