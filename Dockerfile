FROM postgres:17-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/vcp
COPY db ./db
COPY scripts ./scripts
COPY docker ./docker
COPY docker/init.sql /docker-entrypoint-initdb.d/001-project.sql

CMD ["postgres"]
