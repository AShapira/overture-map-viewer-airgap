# syntax=docker/dockerfile:1.7
ARG PLANETILER_VERSION=0.10.2

FROM docker.io/library/golang:1.27.1-alpine3.23@sha256:d9e2f2f07b10cc922da3e80e035c3058810b328d5aef82d2c63680967c5e2ec9 AS s5cmd-builder

ARG S5CMD_VERSION=2.3.0

RUN go install "github.com/peak/s5cmd/v2@v${S5CMD_VERSION}"

FROM docker.io/library/eclipse-temurin:25-jdk-noble@sha256:534968c051301957beae735e7ba1db54d99ddecf08746d3b9d4f318cc132dbc3 AS adapter-builder

ARG PLANETILER_VERSION

# The source patch is deliberately pinned to Planetiler 0.10.2. It replaces only
# the local-file opening expression so registered S3 paths use seekable range reads.
# hadolint ignore=DL3008
RUN test "${PLANETILER_VERSION}" = "0.10.2" && \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl maven unzip && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /app && \
    curl -fsSL "https://github.com/onthegomap/planetiler/releases/download/v${PLANETILER_VERSION}/planetiler.jar" \
      -o /app/planetiler.jar

COPY s3-parquet-adapter/pom.xml /build/s3-parquet-adapter/pom.xml

RUN cd /build/s3-parquet-adapter && \
    mvn --batch-mode --no-transfer-progress dependency:go-offline

COPY s3-parquet-adapter/src /build/s3-parquet-adapter/src

RUN cd /build/s3-parquet-adapter && \
    mvn --batch-mode --no-transfer-progress verify && \
    cp target/s3-parquet-adapter-*-all.jar /app/s3-parquet-adapter.jar && \
    SOURCE_ENTRY="$(unzip -Z1 /app/planetiler.jar | sed -n '/com\/onthegomap\/planetiler\/reader\/parquet\/ParquetInputFile.java$/p' | head -n 1)" && \
    test -n "${SOURCE_ENTRY}" && \
    mkdir -p /tmp/planetiler-patch-src/com/onthegomap/planetiler/reader/parquet /tmp/planetiler-patch-classes && \
    unzip -p /app/planetiler.jar "${SOURCE_ENTRY}" \
      > /tmp/planetiler-patch-src/com/onthegomap/planetiler/reader/parquet/ParquetInputFile.java && \
    grep -Fq 'ParquetReader.makeInputFile(path.toFile())' \
      /tmp/planetiler-patch-src/com/onthegomap/planetiler/reader/parquet/ParquetInputFile.java && \
    sed -i 's@ParquetReader.makeInputFile(path.toFile())@S3InputFiles.resolve(path).orElseGet(() -> ParquetReader.makeInputFile(path.toFile()))@' \
      /tmp/planetiler-patch-src/com/onthegomap/planetiler/reader/parquet/ParquetInputFile.java && \
    javac -cp /app/planetiler.jar:/app/s3-parquet-adapter.jar \
      -d /tmp/planetiler-patch-classes \
      /tmp/planetiler-patch-src/com/onthegomap/planetiler/reader/parquet/ParquetInputFile.java && \
    cd /tmp/planetiler-patch-classes && \
    jar --update --file /app/s3-parquet-adapter.jar com/onthegomap/planetiler/reader/parquet/ParquetInputFile*.class

FROM docker.io/library/eclipse-temurin:25-jdk-noble@sha256:534968c051301957beae735e7ba1db54d99ddecf08746d3b9d4f318cc132dbc3

ARG TARGETARCH
ARG AIRCOMPRESSOR_VERSION=2.0.3
ARG DUCKDB_VERSION=1.5.5

LABEL org.opencontainers.image.title="overture-tiles-airgap"

COPY --from=adapter-builder /app/planetiler.jar /app/planetiler.jar

# hadolint ignore=DL3003,DL3008
RUN mkdir -p /app && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends ca-certificates curl bash gzip tar unzip zip findutils python3 && \
    rm -rf /var/lib/apt/lists/* && \
    DUCKDB_ARCH=$([ "${TARGETARCH}" = "arm64" ] && echo "aarch64" || echo "amd64") && \
    curl -fsSL "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-${DUCKDB_ARCH}.zip" \
      -o duckdb_cli.zip && \
    unzip duckdb_cli.zip -d /usr/local/bin/ && \
    rm duckdb_cli.zip && \
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
COPY --from=adapter-builder /app/s3-parquet-adapter.jar /app/s3-parquet-adapter.jar
COPY profiles /app/profiles
COPY bbox.sh /app/bbox.sh
COPY run-airgap.sh /app/run-airgap.sh
COPY generator.py capacity.py pmtiles_check.py capacity-priors.json /app/

RUN chmod +x /app/*.sh

WORKDIR /work
ENTRYPOINT ["/app/run-airgap.sh"]
