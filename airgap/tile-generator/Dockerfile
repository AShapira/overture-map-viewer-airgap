# syntax=docker/dockerfile:1.7
FROM amazoncorretto:22

ARG TARGETARCH
ARG DUCKDB_VERSION=1.5.1
ARG PLANETILER_VERSION=0.10.2
ARG S5CMD_VERSION=2.3.0

LABEL org.opencontainers.image.title="overture-tiles-airgap"

RUN mkdir -p /app && \
    dnf install -y gzip tar unzip findutils && dnf clean all && \
    S5CMD_ARCH=$([ "${TARGETARCH}" = "arm64" ] && echo "Linux-arm64" || echo "Linux-64bit") && \
    curl -fsSL "https://github.com/peak/s5cmd/releases/download/v${S5CMD_VERSION}/s5cmd_${S5CMD_VERSION}_${S5CMD_ARCH}.tar.gz" \
      -o s5cmd.tar.gz && \
    tar -xzf s5cmd.tar.gz s5cmd && \
    mv s5cmd /usr/local/bin/s5cmd && \
    rm s5cmd.tar.gz && \
    DUCKDB_ARCH=$([ "${TARGETARCH}" = "arm64" ] && echo "aarch64" || echo "amd64") && \
    curl -fsSL "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-${DUCKDB_ARCH}.zip" \
      -o duckdb_cli.zip && \
    unzip duckdb_cli.zip -d /usr/local/bin/ && \
    rm duckdb_cli.zip && \
    curl -fsSL "https://github.com/onthegomap/planetiler/releases/download/v${PLANETILER_VERSION}/planetiler.jar" \
      -o /app/planetiler.jar

COPY profiles /app/profiles
COPY bbox.sh /app/bbox.sh
COPY run-airgap.sh /app/run-airgap.sh

RUN chmod +x /app/*.sh

WORKDIR /work
ENTRYPOINT ["/app/run-airgap.sh"]
