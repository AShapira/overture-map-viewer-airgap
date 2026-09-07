package com.onthegomap.planetiler.reader.parquet;

import static org.junit.jupiter.api.Assertions.*;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import org.apache.parquet.conf.PlainParquetConfiguration;
import org.apache.parquet.example.data.simple.SimpleGroupFactory;
import org.apache.parquet.hadoop.example.ExampleParquetWriter;
import org.apache.parquet.hadoop.metadata.BlockMetaData;
import org.apache.parquet.io.LocalOutputFile;
import org.apache.parquet.schema.MessageTypeParser;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.locationtech.jts.geom.Envelope;
import org.locationtech.jts.geom.GeometryFactory;
import org.locationtech.jts.geom.Coordinate;
import org.locationtech.jts.io.WKBWriter;

class AirgapToolsTest {
  @TempDir Path temp;
  @Test void boundsRejectNonfiniteAndReversed() {
    for (String value : new String[]{"NaN,0,1,1", "0,0,0,1", "1,0,0,1", "-181,0,1,1"})
      assertThrows(IllegalArgumentException.class, () -> AirgapTools.envelope(value));
  }
  @Test void absentStatisticsRemainCandidates() {
    assertTrue(AirgapTools.candidate(new BlockMetaData(), new Envelope(34, 36, 29, 34)));
  }
  @Test void exportRetainsSchemaAndValidEmptyGeoMetadata() throws Exception {
    var schema = MessageTypeParser.parseMessageType("message test { required binary id (UTF8); required binary geometry; required group bbox { required double xmin; required double ymin; required double xmax; required double ymax; } }");
    String geo = "{\"version\":\"1.1.0\",\"primary_column\":\"geometry\",\"columns\":{\"geometry\":{\"encoding\":\"WKB\",\"geometry_types\":[\"Point\"]}}}";
    Path input = temp.resolve("input/theme=places/type=place"); Files.createDirectories(input);
    var factory = new SimpleGroupFactory(schema);
    try (var writer = ExampleParquetWriter.builder(new LocalOutputFile(input.resolve("data.parquet")))
        .withConf(new PlainParquetConfiguration()).withType(schema).withExtraMetaData(Map.of("geo", geo)).build()) {
      for (double x : new double[]{35, 100}) {
        var group = factory.newGroup().append("id", "id" + x).append("geometry", org.apache.parquet.io.api.Binary.fromConstantByteArray(new WKBWriter().write(new GeometryFactory().createPoint(new Coordinate(x, 32)))));
        group.addGroup("bbox").append("xmin", x).append("xmax", x).append("ymin", 32.).append("ymax", 32.);
        writer.write(group);
      }
    }
    var before = Files.readAllBytes(input.resolve("data.parquet"));
    Path output = temp.resolve("output");
    AirgapTools.export(temp.resolve("input").toString(), "places", new Envelope(34, 36, 31, 33), output, null);
    try (var reader = org.apache.parquet.hadoop.ParquetFileReader.open(new org.apache.parquet.io.LocalInputFile(output.resolve("theme=places/type=place/part-000000.parquet")))) {
      assertEquals(schema, reader.getFooter().getFileMetaData().getSchema());
      assertEquals(1, reader.getRecordCount());
      assertEquals(geo, reader.getFooter().getFileMetaData().getKeyValueMetaData().get("geo"));
    }
    Path empty = temp.resolve("empty");
    AirgapTools.export(temp.resolve("input").toString(), "places", new Envelope(0, 1, 0, 1), empty, null);
    try (var reader = org.apache.parquet.hadoop.ParquetFileReader.open(new org.apache.parquet.io.LocalInputFile(empty.resolve("theme=places/type=place/part-000000.parquet")))) {
      assertEquals(0, reader.getRecordCount());
      assertEquals(geo, reader.getFooter().getFileMetaData().getKeyValueMetaData().get("geo"));
    }
    assertArrayEquals(before, Files.readAllBytes(input.resolve("data.parquet")));
  }
}
