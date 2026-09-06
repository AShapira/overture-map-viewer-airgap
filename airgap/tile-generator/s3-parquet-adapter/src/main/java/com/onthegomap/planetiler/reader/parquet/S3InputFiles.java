package com.onthegomap.planetiler.reader.parquet;

import java.io.IOException;
import java.net.URI;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.stream.Stream;
import org.apache.parquet.io.InputFile;
import org.apache.logging.log4j.Level;
import org.apache.logging.log4j.core.config.Configurator;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.auth.credentials.EnvironmentVariableCredentialsProvider;
import software.amazon.awssdk.core.ResponseInputStream;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.GetObjectResponse;
import software.amazon.awssdk.services.s3.model.ListObjectsV2Request;
import software.amazon.awssdk.services.s3.model.S3Object;

/** Registers seekable S3-backed parquet inputs behind zero-byte local path indexes. */
public final class S3InputFiles {
  private static final Logger LOGGER = LoggerFactory.getLogger(S3InputFiles.class);
  private static final Map<Path, InputFile> REGISTRY = new ConcurrentHashMap<>();

  private S3InputFiles() {}

  /** Called by the patched Planetiler parquet reader before it opens a local file. */
  public static Optional<InputFile> resolve(Path path) {
    return Optional.ofNullable(REGISTRY.get(normalize(path)));
  }

  public static Source open(String sourceUri, String theme) throws IOException {
    Configurator.setLevel("software.amazon.awssdk", Level.WARN);
    URI uri = URI.create(sourceUri);
    if (!"s3".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null || uri.getHost().isBlank()) {
      throw new IllegalArgumentException("S3 source must be an s3://bucket/prefix URI: " + sourceUri);
    }
    String bucket = uri.getHost();
    String rootPrefix = stripSlashes(uri.getPath());
    String themePrefix = rootPrefix.isEmpty() ? "theme=" + theme + "/" : rootPrefix + "/theme=" + theme + "/";
    S3Client client = createClient();
    Path indexRoot = null;
    List<Path> paths = new ArrayList<>();
    AtomicLong rangeRequests = new AtomicLong();
    AtomicLong rangeBytes = new AtomicLong();
    try {
      List<S3Object> objects = client.listObjectsV2Paginator(ListObjectsV2Request.builder()
              .bucket(bucket)
              .prefix(themePrefix)
              .build())
          .contents().stream()
          .filter(object -> isThemeParquet(themePrefix, object.key()))
          .sorted(Comparator.comparing(S3Object::key))
          .toList();
      if (objects.isEmpty()) {
        throw new IOException("No GeoParquet objects found under s3://" + bucket + "/" + themePrefix);
      }

      indexRoot = Files.createTempDirectory("planetiler-s3-index-");
      long totalBytes = 0;
      for (S3Object object : objects) {
        String relativeKey = object.key().substring(rootPrefix.isEmpty() ? 0 : rootPrefix.length() + 1);
        Path relativePath = Path.of(relativeKey).normalize();
        if (relativePath.isAbsolute() || relativePath.startsWith("..")) {
          throw new IOException("Unsafe S3 object key: " + object.key());
        }
        Path placeholder = indexRoot.resolve(relativePath).normalize();
        if (!placeholder.startsWith(indexRoot)) {
          throw new IOException("Unsafe S3 object key: " + object.key());
        }
        Files.createDirectories(placeholder.getParent());
        Files.createFile(placeholder);
        var input = new S3RangeInputFile(object.size(), (offset, length) -> {
          long end = offset + length - 1;
          GetObjectRequest request = GetObjectRequest.builder()
              .bucket(bucket)
              .key(object.key())
              .range("bytes=" + offset + "-" + end)
              .build();
          try (ResponseInputStream<GetObjectResponse> response = client.getObject(request)) {
            byte[] bytes = response.readNBytes(length + 1);
            if (bytes.length != length) {
              throw new IOException("S3 range read for " + object.key() + " returned " + bytes.length
                  + " bytes; expected " + length);
            }
            rangeRequests.incrementAndGet();
            rangeBytes.addAndGet(bytes.length);
            return bytes;
          }
        });
        REGISTRY.put(normalize(placeholder), input);
        paths.add(placeholder);
        totalBytes += object.size();
      }
      LOGGER.info("Indexed {} S3 GeoParquet object(s) for theme {} ({} source bytes; no source download)",
          paths.size(), theme, totalBytes);
      return new Source(client, indexRoot, List.copyOf(paths), rangeRequests, rangeBytes, theme);
    } catch (Exception exception) {
      paths.forEach(path -> REGISTRY.remove(normalize(path)));
      deleteTree(indexRoot);
      client.close();
      if (exception instanceof IOException ioException) {
        throw ioException;
      }
      if (exception instanceof RuntimeException runtimeException) {
        throw runtimeException;
      }
      throw new IOException("Could not index S3 GeoParquet source", exception);
    }
  }

  public static S3Client createClient() {
    Configurator.setLevel("software.amazon.awssdk", Level.WARN);
    String region = firstNonBlank(System.getenv("S3_REGION"), System.getenv("AWS_REGION"), "us-west-2");
    String endpoint = System.getenv("S3_ENDPOINT_URL");
    var credentials = System.getenv("AWS_ACCESS_KEY_ID") == null
        ? DefaultCredentialsProvider.create()
        : EnvironmentVariableCredentialsProvider.create();
    var builder = S3Client.builder()
        .region(Region.of(region))
        .credentialsProvider(credentials)
        .httpClientBuilder(UrlConnectionHttpClient.builder())
        .serviceConfiguration(S3Configuration.builder().pathStyleAccessEnabled(endpoint != null && !endpoint.isBlank()).build());
    if (endpoint != null && !endpoint.isBlank()) {
      builder.endpointOverride(URI.create(endpoint));
    }
    return builder.build();
  }

  private static boolean isThemeParquet(String themePrefix, String key) {
    if (!key.startsWith(themePrefix) || !key.endsWith(".parquet")) {
      return false;
    }
    String remainder = key.substring(themePrefix.length());
    String[] parts = remainder.split("/", -1);
    return parts.length == 2 && parts[0].startsWith("type=") && parts[0].length() > 5 && !parts[1].isBlank();
  }

  private static Path normalize(Path path) {
    return path.toAbsolutePath().normalize();
  }

  private static String stripSlashes(String value) {
    return value == null ? "" : value.replaceAll("^/+|/+$", "");
  }

  private static String firstNonBlank(String... values) {
    for (String value : values) {
      if (value != null && !value.isBlank()) {
        return value;
      }
    }
    throw new IllegalStateException("No non-blank value");
  }

  private static void deleteTree(Path root) {
    if (root == null || !Files.exists(root)) {
      return;
    }
    try (Stream<Path> entries = Files.walk(root)) {
      entries.sorted(Comparator.reverseOrder()).forEach(path -> {
        try {
          Files.deleteIfExists(path);
        } catch (IOException exception) {
          LOGGER.warn("Could not remove temporary S3 path index {}", path, exception);
        }
      });
    } catch (IOException exception) {
      LOGGER.warn("Could not enumerate temporary S3 path index {}", root, exception);
    }
  }

  public static final class Source implements AutoCloseable {
    private final S3Client client;
    private final Path indexRoot;
    private final List<Path> paths;
    private final AtomicLong rangeRequests;
    private final AtomicLong rangeBytes;
    private final String theme;
    private boolean closed;

    private Source(S3Client client, Path indexRoot, List<Path> paths, AtomicLong rangeRequests,
        AtomicLong rangeBytes, String theme) {
      this.client = client;
      this.indexRoot = indexRoot;
      this.paths = paths;
      this.rangeRequests = rangeRequests;
      this.rangeBytes = rangeBytes;
      this.theme = theme;
    }

    public List<Path> paths() {
      return paths;
    }

    @Override
    public synchronized void close() {
      if (closed) {
        return;
      }
      closed = true;
      paths.forEach(path -> REGISTRY.remove(normalize(path)));
      client.close();
      deleteTree(indexRoot);
      LOGGER.info("Closed S3 GeoParquet source for theme {} after {} range request(s) and {} bytes read",
          theme, rangeRequests.get(), rangeBytes.get());
    }
  }
}
