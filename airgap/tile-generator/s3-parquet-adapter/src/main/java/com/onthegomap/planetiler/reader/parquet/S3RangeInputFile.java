package com.onthegomap.planetiler.reader.parquet;

import java.io.EOFException;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.Objects;
import org.apache.parquet.io.InputFile;
import org.apache.parquet.io.SeekableInputStream;

final class S3RangeInputFile implements InputFile {
  static final int DEFAULT_READ_SIZE = 8 * 1024 * 1024;

  @FunctionalInterface
  interface RangeReader {
    byte[] read(long offset, int length) throws IOException;
  }

  private final long length;
  private final int readSize;
  private final RangeReader reader;

  S3RangeInputFile(long length, RangeReader reader) {
    this(length, DEFAULT_READ_SIZE, reader);
  }

  S3RangeInputFile(long length, int readSize, RangeReader reader) {
    if (length < 0) {
      throw new IllegalArgumentException("length must not be negative");
    }
    if (readSize <= 0) {
      throw new IllegalArgumentException("readSize must be positive");
    }
    this.length = length;
    this.readSize = readSize;
    this.reader = Objects.requireNonNull(reader);
  }

  @Override
  public long getLength() {
    return length;
  }

  @Override
  public SeekableInputStream newStream() {
    return new Stream();
  }

  private final class Stream extends SeekableInputStream {
    private long position;
    private long bufferStart = -1;
    private byte[] buffer = new byte[0];
    private boolean closed;

    @Override
    public long getPos() throws IOException {
      ensureOpen();
      return position;
    }

    @Override
    public void seek(long newPosition) throws IOException {
      ensureOpen();
      if (newPosition < 0 || newPosition > length) {
        throw new IOException("Invalid seek position " + newPosition + " for object length " + length);
      }
      position = newPosition;
    }

    @Override
    public int read() throws IOException {
      ensureOpen();
      if (!ensureBuffered()) {
        return -1;
      }
      return buffer[(int) (position++ - bufferStart)] & 0xff;
    }

    @Override
    public int read(byte[] target, int offset, int requested) throws IOException {
      ensureOpen();
      Objects.checkFromIndexSize(offset, requested, target.length);
      if (requested == 0) {
        return 0;
      }
      if (position >= length) {
        return -1;
      }
      int total = 0;
      while (total < requested && position < length) {
        ensureBuffered();
        int bufferOffset = (int) (position - bufferStart);
        int available = buffer.length - bufferOffset;
        int count = Math.min(requested - total, available);
        System.arraycopy(buffer, bufferOffset, target, offset + total, count);
        position += count;
        total += count;
      }
      return total;
    }

    @Override
    public int read(ByteBuffer target) throws IOException {
      ensureOpen();
      if (!target.hasRemaining()) {
        return 0;
      }
      if (position >= length) {
        return -1;
      }
      int total = 0;
      while (target.hasRemaining() && position < length) {
        ensureBuffered();
        int bufferOffset = (int) (position - bufferStart);
        int count = Math.min(target.remaining(), buffer.length - bufferOffset);
        target.put(buffer, bufferOffset, count);
        position += count;
        total += count;
      }
      return total;
    }

    @Override
    public void readFully(byte[] target) throws IOException {
      readFully(target, 0, target.length);
    }

    @Override
    public void readFully(byte[] target, int offset, int requested) throws IOException {
      Objects.checkFromIndexSize(offset, requested, target.length);
      int total = 0;
      while (total < requested) {
        int count = read(target, offset + total, requested - total);
        if (count < 0) {
          throw new EOFException("Reached end of S3 object after " + total + " of " + requested + " bytes");
        }
        total += count;
      }
    }

    @Override
    public void readFully(ByteBuffer target) throws IOException {
      while (target.hasRemaining()) {
        if (read(target) < 0) {
          throw new EOFException("Reached end of S3 object with " + target.remaining() + " bytes remaining");
        }
      }
    }

    @Override
    public void close() {
      closed = true;
      buffer = new byte[0];
    }

    private boolean ensureBuffered() throws IOException {
      if (position >= length) {
        return false;
      }
      if (bufferStart <= position && position < bufferStart + buffer.length) {
        return true;
      }
      bufferStart = (position / readSize) * readSize;
      int requested = (int) Math.min(readSize, length - bufferStart);
      buffer = reader.read(bufferStart, requested);
      if (buffer.length != requested) {
        throw new IOException("S3 range read returned " + buffer.length + " bytes; expected " + requested);
      }
      return true;
    }

    private void ensureOpen() throws IOException {
      if (closed) {
        throw new IOException("Stream is closed");
      }
    }
  }
}
