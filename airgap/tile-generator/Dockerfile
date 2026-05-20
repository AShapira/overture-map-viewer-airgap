# syntax=docker/dockerfile:1.7
FROM golang:1.25.10-alpine3.23 AS s5cmd-builder

ARG S5CMD_VERSION=2.3.0

RUN go install "github.com/peak/s5cmd/v2@v${S5CMD_VERSION}"

FROM eclipse-temurin:25-jre-noble

ARG TARGETARCH
ARG AIRCOMPRESSOR_VERSION=2.0.3
ARG DUCKDB_VERSION=1.5.1
ARG PLANETILER_VERSION=0.10.2

LABEL org.opencontainers.image.title="overture-tiles-airgap"

# hadolint ignore=DL3003,DL3008
RUN mkdir -p /app && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends ca-certificates curl bash gzip tar unzip zip findutils && \
    rm -rf /var/lib/apt/lists/* && \
    DUCKDB_ARCH=$([ "${TARGETARCH}" = "arm64" ] && echo "aarch64" || echo "amd64") && \
    curl -fsSL "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-${DUCKDB_ARCH}.zip" \
      -o duckdb_cli.zip && \
    unzip duckdb_cli.zip -d /usr/local/bin/ && \
    rm duckdb_cli.zip && \
    curl -fsSL "https://github.com/onthegomap/planetiler/releases/download/v${PLANETILER_VERSION}/planetiler.jar" \
      -o /app/planetiler.jar && \
    : "Patch Planetiler 0.10.2 shaded aircompressor until upstream includes the fix" && \
    curl -fsSL "https://repo.maven.apache.org/maven2/io/airlift/aircompressor/${AIRCOMPRESSOR_VERSION}/aircompressor-${AIRCOMPRESSOR_VERSION}.jar" \
      -o /tmp/aircompressor.jar && \
    mkdir -p /tmp/aircompressor-patch && \
    unzip -q /tmp/aircompressor.jar "io/airlift/compress/*" "META-INF/maven/io.airlift/aircompressor/*" \
      -d /tmp/aircompressor-patch && \
    cd /tmp/aircompressor-patch && \
    zip -qr /app/planetiler.jar io META-INF && \
    rm -rf /tmp/aircompressor.jar /tmp/aircompressor-patch

COPY --from=s5cmd-builder /go/bin/s5cmd /usr/local/bin/s5cmd
COPY profiles /app/profiles
COPY bbox.sh /app/bbox.sh
COPY run-airgap.sh /app/run-airgap.sh

RUN chmod +x /app/*.sh

WORKDIR /work
ENTRYPOINT ["/app/run-airgap.sh"]
