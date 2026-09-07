package com.onthegomap.planetiler.reader.parquet;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.io.EOFException;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.junit.jupiter.api.Test;

class S3RangeInputFileTest {
  private final byte[] source = "0123456789abcdef".getBytes();
  private final List<String> ranges = new ArrayList<>();
  private final S3RangeInputFile input = new S3RangeInputFile(source.length, 4, (offset, length) -> {
    ranges.add(offset + ":" + length);
    return Arrays.copyOfRange(source, (int) offset, (int) offset + length);
  });

  @Test
  void supportsSeekAndBufferedReads() throws Exception {
    try (var stream = input.newStream()) {
      assertEquals('0', stream.read());
      assertEquals('1', stream.read());
      stream.seek(6);
      byte[] bytes = new byte[5];
      stream.readFully(bytes);
      assertArrayEquals("6789a".getBytes(), bytes);
      assertEquals(List.of("0:4", "4:4", "8:4"), ranges);
    }
  }

  @Test
  void supportsByteBuffersAndEndOfFile() throws Exception {
    try (var stream = input.newStream()) {
      stream.seek(14);
      ByteBuffer buffer = ByteBuffer.allocate(2);
      stream.readFully(buffer);
      assertArrayEquals("ef".getBytes(), buffer.array());
      assertEquals(-1, stream.read());
      assertThrows(EOFException.class, () -> stream.readFully(new byte[1]));
    }
  }

  @Test
  void rejectsShortRangeResponses() {
    var shortInput = new S3RangeInputFile(10, 4, (offset, length) -> new byte[length - 1]);
    assertThrows(Exception.class, () -> shortInput.newStream().read());
  }
}
