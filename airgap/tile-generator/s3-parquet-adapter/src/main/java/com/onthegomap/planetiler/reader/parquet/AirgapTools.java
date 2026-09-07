package com.onthegomap.planetiler.reader.parquet;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.onthegomap.planetiler.config.Bounds;
import java.io.IOException;
import java.net.URI;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.stream.Stream;
import org.apache.parquet.conf.PlainParquetConfiguration;
import org.apache.parquet.example.data.Group;
import org.apache.parquet.filter2.compat.FilterCompat;
import org.apache.parquet.hadoop.ParquetFileReader;
import org.apache.parquet.hadoop.ParquetReader;
import org.apache.parquet.hadoop.ParquetWriter;
import org.apache.parquet.hadoop.api.ReadSupport;
import org.apache.parquet.hadoop.example.ExampleParquetWriter;
import org.apache.parquet.hadoop.example.GroupReadSupport;
import org.apache.parquet.hadoop.metadata.*;
import org.apache.parquet.io.*;
import org.locationtech.jts.geom.Envelope;
import org.locationtech.jts.io.WKBReader;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.*;

/** Offline metadata inspection and bounded, schema-preserving export. No source payload staging. */
public final class AirgapTools {
  static final ObjectMapper JSON = new ObjectMapper();
  static final long PART_BYTES = 128L << 20;
  record SourceFile(String uri, String type, String identity, InputFile input) {}

  static final class Sources implements AutoCloseable {
    final List<SourceFile> files = new ArrayList<>();
    S3Client client;
    Sources(String source, String theme) throws IOException {
      if (source.startsWith("s3://")) {
        URI uri = URI.create(source);
        client = S3InputFiles.createClient();
        String root = uri.getPath().replaceAll("^/+|/+$", "");
        String prefix = (root.isEmpty() ? "" : root + "/") + "theme=" + theme + "/";
        try {
          for (var object : client.listObjectsV2Paginator(ListObjectsV2Request.builder()
              .bucket(uri.getHost()).prefix(prefix).build()).contents()) {
            String[] parts = object.key().substring(prefix.length()).split("/", -1);
            if (parts.length != 2 || !parts[0].startsWith("type=") || !parts[1].endsWith(".parquet")) continue;
            String key = object.key();
            InputFile input = new S3RangeInputFile(object.size(), 64 * 1024, (offset, length) -> {
              try (var stream = client.getObject(GetObjectRequest.builder().bucket(uri.getHost()).key(key)
                  .ifMatch(object.eTag()).range("bytes=" + offset + "-" + (offset + length - 1)).build())) {
                byte[] bytes = stream.readNBytes(length + 1);
                if (bytes.length != length) throw new IOException("Invalid S3 range length: " + key);
                return bytes;
              }
            });
            files.add(new SourceFile("s3://" + uri.getHost() + "/" + key, parts[0].substring(5),
                object.eTag() + ":" + object.size(), input));
          }
        } catch (RuntimeException e) { close(); throw e; }
      } else {
        Path dir = Path.of(source).resolve("theme=" + theme);
        try (Stream<Path> paths = Files.walk(dir, 2)) {
          for (Path path : paths.filter(Files::isRegularFile).sorted().toList()) {
            if (!path.toString().endsWith(".parquet") || !path.getParent().getFileName().toString().startsWith("type=")) continue;
            files.add(new SourceFile(path.toString(), path.getParent().getFileName().toString().substring(5),
                Files.size(path) + ":" + Files.getLastModifiedTime(path).toMillis(), new LocalInputFile(path)));
          }
        }
      }
      files.sort(Comparator.comparing(SourceFile::uri));
      if (files.isEmpty()) { close(); throw new IOException("No GeoParquet objects for theme " + theme); }
    }
    public void close() { if (client != null) client.close(); }
  }

  static Envelope envelope(String value) {
    if (value.isBlank()) return new Envelope(-180, 180, -90, 90);
    String[] parts = value.split(",", -1);
    if (parts.length != 4) throw new IllegalArgumentException("BBOX requires west,south,east,north");
    double[] v = Arrays.stream(parts).mapToDouble(Double::parseDouble).toArray();
    if (Arrays.stream(v).anyMatch(x -> !Double.isFinite(x)) || v[0] >= v[2] || v[1] >= v[3] ||
        v[0] < -180 || v[2] > 180 || v[1] < -90 || v[3] > 90) throw new IllegalArgumentException("Invalid BBOX");
    return new Envelope(v[0], v[2], v[1], v[3]);
  }

  /** Statistics exclusion is conservative, including absent/null statistics. */
  static boolean candidate(BlockMetaData block, Envelope box) {
    for (var col : block.getColumns()) {
      var stats = col.getStatistics();
      if (stats == null || !stats.hasNonNullValue() || !stats.isNumNullsSet() || stats.getNumNulls() > 0) continue;
      String name = col.getPath().toDotString();
      if (!(stats.genericGetMin() instanceof Number min) || !(stats.genericGetMax() instanceof Number max)) continue;
      if (name.equals("bbox.xmin") && min.doubleValue() > box.getMaxX() ||
          name.equals("bbox.xmax") && max.doubleValue() < box.getMinX() ||
          name.equals("bbox.ymin") && min.doubleValue() > box.getMaxY() ||
          name.equals("bbox.ymax") && max.doubleValue() < box.getMinY()) return false;
    }
    return true;
  }

  static Map<String, Object> inventory(String source, String theme, Envelope box) throws Exception {
    List<Map<String, Object>> objects = new ArrayList<>();
    try (Sources sources = new Sources(source, theme)) {
      for (SourceFile file : sources.files) {
        try (var reader = ParquetFileReader.open(file.input())) {
          var footer = reader.getFooter();
          var geo = GeoParquetMetadata.parse(footer.getFileMetaData());
          List<Map<String, Object>> groups = new ArrayList<>();
          int index = 0;
          for (var block : footer.getBlocks()) {
            boolean matches = geo.primaryColumnMetadata().envelope().intersects(box) && candidate(block, box);
            long compressed = block.getColumns().stream().mapToLong(ColumnChunkMetaData::getTotalSize).sum();
            long geometry = block.getColumns().stream().filter(c -> c.getPath().toDotString().equals(geo.primaryColumn()))
                .mapToLong(ColumnChunkMetaData::getTotalUncompressedSize).sum();
            long stats = block.getColumns().stream().filter(c -> c.getPath().toDotString().startsWith("bbox."))
                .filter(c -> c.getStatistics() != null && c.getStatistics().hasNonNullValue() &&
                    c.getStatistics().isNumNullsSet() && c.getStatistics().getNumNulls() == 0 &&
                    c.getStatistics().genericGetMin() instanceof Number lo && Double.isFinite(lo.doubleValue()) &&
                    c.getStatistics().genericGetMax() instanceof Number hi && Double.isFinite(hi.doubleValue())).count();
            var group = new LinkedHashMap<String, Object>(Map.of("index", index++, "rows", block.getRowCount(), "compressed_bytes", compressed,
                "uncompressed_bytes", block.getTotalByteSize(), "geometry_bytes", geometry,
                "candidate", matches, "bbox_statistics_complete", stats == 4,
                "start", block.getStartingPos(), "end", block.getStartingPos() + compressed));
            Map<String, Double> extent = new HashMap<>();
            if (stats == 4) {
              for (var col : block.getColumns()) {
                String name = col.getPath().toDotString();
                if (Set.of("bbox.xmin", "bbox.ymin", "bbox.xmax", "bbox.ymax").contains(name)) {
                  var value = name.endsWith("min") ? col.getStatistics().genericGetMin() : col.getStatistics().genericGetMax();
                  extent.put(name, ((Number) value).doubleValue());
                }
              }
            }
            group.put("rows_per_square_degree", extent.size() == 4 ? block.getRowCount() / Math.max(1e-12,
                (extent.get("bbox.xmax") - extent.get("bbox.xmin")) * (extent.get("bbox.ymax") - extent.get("bbox.ymin"))) : null);
            groups.add(group);
          }
          Map<String, Object> obj = new LinkedHashMap<>();
          obj.put("uri", file.uri()); obj.put("type", file.type()); obj.put("identity", file.identity());
          obj.put("bytes", file.input().getLength()); obj.put("row_groups", groups);
          objects.add(obj);
        }
      }
    }
    return Map.of("theme", theme, "objects", objects);
  }

  static final class GroupBuilder extends ParquetReader.Builder<Group> {
    GroupBuilder(InputFile input) { super(input, new PlainParquetConfiguration()); }
    @Override protected ReadSupport<Group> getReadSupport() { return new GroupReadSupport(); }
  }

  static String digest(Path file) throws Exception {
    MessageDigest digest = MessageDigest.getInstance("SHA-256");
    try (var in = Files.newInputStream(file)) {
      byte[] bytes = new byte[1024 * 1024];
      for (int n; (n = in.read(bytes)) >= 0;) digest.update(bytes, 0, n);
    }
    return HexFormat.of().formatHex(digest.digest());
  }

  public static void verifyRemote(S3Client client, String remote, long size, String sha) throws Exception {
    URI uri = URI.create(remote);
    MessageDigest digest = MessageDigest.getInstance("SHA-256");
    long read = 0;
    try (var in = client.getObject(GetObjectRequest.builder().bucket(uri.getHost()).key(uri.getPath().substring(1)).build())) {
      byte[] bytes = new byte[1024 * 1024];
      for (int n; (n = in.read(bytes)) >= 0;) { digest.update(bytes, 0, n); read += n; }
    }
    if (read != size || !HexFormat.of().formatHex(digest.digest()).equals(sha))
      throw new IOException("Remote SHA-256/size mismatch for " + remote);
  }

  static void completePart(Path part, Path output, String upload, S3Client client, long rows) throws Exception {
    String sha = digest(part);
    String target = upload.isBlank() ? part.toString() : upload.replaceAll("/+$", "") + "/" + output.relativize(part);
    if (!upload.isBlank()) {
      URI uri = URI.create(target);
      client.putObject(PutObjectRequest.builder().bucket(uri.getHost()).key(uri.getPath().substring(1))
          .metadata(Map.of("sha256", sha)).build(), RequestBody.fromFile(part));
      verifyRemote(client, target, Files.size(part), sha);
    }
    System.out.println(JSON.writeValueAsString(Map.of("part", target, "bytes", Files.size(part), "rows", rows, "sha256", sha)));
    if (!upload.isBlank()) Files.delete(part);
  }

  /** Export selected records without changing schemas, nesting, geometry, or source metadata. */
  static void export(String source, String theme, Envelope box, Path output, Path selectionPath) throws Exception {
    Map<String, List<Map<String, Number>>> selection = selectionPath == null ? null :
        JSON.readValue(Files.readString(selectionPath), Map.class);
    String upload = System.getenv().getOrDefault("EXPORT_S3_PREFIX", "");
    try (Sources sources = new Sources(source, theme); S3Client publisher = upload.isBlank() ? null : S3InputFiles.createClient()) {
      int sequence = 0;
      Set<String> emitted = new HashSet<>();
      for (SourceFile file : sources.files) {
        if (selection != null && !selection.containsKey(file.uri())) continue;
        try (var metadata = ParquetFileReader.open(file.input())) {
          var footer = metadata.getFooter(); var schema = footer.getFileMetaData().getSchema();
          var exportMetadata = new HashMap<>(footer.getFileMetaData().getKeyValueMetaData());
          // ParquetWriter owns this key; carrying it back through extra metadata
          // makes a second export fail. Geometry/schema metadata is preserved.
          exportMetadata.remove("writer.model.name");
          var geo = GeoParquetMetadata.parse(footer.getFileMetaData());
          var filter = geo.primaryColumnMetadata().bboxFilter(schema, new Bounds(box));
          var ranges = selection == null ? List.<Map<String, Number>>of(Map.of("start", 0L, "end", Long.MAX_VALUE, "limit", Long.MAX_VALUE)) : selection.get(file.uri());
          Path dir = output.resolve("theme=" + theme).resolve("type=" + file.type()); Files.createDirectories(dir);
          for (var range : ranges) {
            boolean intersects = geo.primaryColumnMetadata().envelope().intersects(box);
            if (!intersects && emitted.contains(file.type())) continue;
            Path part = dir.resolve(String.format(Locale.ROOT, "part-%06d.parquet", sequence++));
            long rows = 0, total = 0;
            var builder = new GroupBuilder(file.input()).withFileRange(range.get("start").longValue(), range.get("end").longValue());
            if (filter != null) builder.withFilter(FilterCompat.get(filter));
            ParquetWriter<Group> writer = null;
            try (var reader = builder.build()) {
              writer = ExampleParquetWriter.builder(new LocalOutputFile(part)).withConf(new PlainParquetConfiguration())
                  .withType(schema).withExtraMetaData(exportMetadata)
                  .withCompressionCodec(CompressionCodecName.ZSTD).withRowGroupSize(16L << 20).build();
              Group group;
              while (intersects && total < range.get("limit").longValue() && (group = reader.read()) != null) {
                if (filter == null && !box.contains(new Envelope(-180, 180, -90, 90))) {
                  if (!geo.primaryColumnMetadata().encoding().equalsIgnoreCase("WKB")) throw new IOException("BBOX export requires WKB or covering bbox columns");
                  if (group.getFieldRepetitionCount(geo.primaryColumn()) == 0 || !new WKBReader().read(group.getBinary(geo.primaryColumn(), 0).getBytes()).getEnvelopeInternal().intersects(box)) continue;
                }
                writer.write(group); rows++; total++;
                if (writer.getDataSize() >= PART_BYTES || rows >= 250_000) {
                  writer.close(); writer = null; completePart(part, output, upload, publisher, rows); emitted.add(file.type());
                  part = dir.resolve(String.format(Locale.ROOT, "part-%06d.parquet", sequence++)); rows = 0;
                  writer = ExampleParquetWriter.builder(new LocalOutputFile(part)).withConf(new PlainParquetConfiguration())
                      .withType(schema).withExtraMetaData(exportMetadata)
                      .withCompressionCodec(CompressionCodecName.ZSTD).withRowGroupSize(16L << 20).build();
                }
              }
              writer.close(); writer = null;
              if (rows > 0 || !emitted.contains(file.type())) { completePart(part, output, upload, publisher, rows); emitted.add(file.type()); }
              else Files.delete(part);
            } finally { if (writer != null) writer.close(); }
          }
        }
      }
    }
  }

  public static void main(String[] args) throws Exception {
    if (args.length < 1) throw new IllegalArgumentException("inventory|export|verify-remote");
    switch (args[0]) {
      case "inventory" -> System.out.println(JSON.writeValueAsString(inventory(args[1], args[2], envelope(args[3]))));
      case "export" -> export(args[1], args[2], envelope(args[3]), Path.of(args[4]), args.length > 5 ? Path.of(args[5]) : null);
      case "verify-remote" -> { try (var client = S3InputFiles.createClient()) { verifyRemote(client, args[1], Long.parseLong(args[2]), args[3]); } }
      case "destination" -> {
        URI uri = URI.create(args[1]);
        try (var client = S3InputFiles.createClient()) {
          long bytes = 0, archives = 0;
          for (var object : client.listObjectsV2Paginator(ListObjectsV2Request.builder().bucket(uri.getHost())
              .prefix(uri.getPath().substring(1).replaceAll("/+$", "") + "/").build()).contents()) {
            bytes += object.size();
            if (object.key().endsWith(".pmtiles")) archives++;
          }
          System.out.println(JSON.writeValueAsString(Map.of("bytes", bytes, "archives", archives)));
        }
      }
      default -> throw new IllegalArgumentException("Unknown operation: " + args[0]);
    }
  }
}
