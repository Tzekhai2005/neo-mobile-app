import 'dart:typed_data';

/// Pre-allocated Circular Ring Buffer for High-Throughput 250 SPS Data
/// Ensures 0 GC (Garbage Collection) memory allocations during streaming.
class EegCircularBuffer {
  final int capacity;
  final Float64List _data;
  int _writeIndex = 0;
  int _totalWritten = 0;

  EegCircularBuffer({this.capacity = 1250}) : _data = Float64List(1250);

  void write(double sample) {
    _data[_writeIndex] = sample;
    _writeIndex = (_writeIndex + 1) % capacity;
    _totalWritten++;
  }

  /// Copies samples into an output buffer in chronological order
  void readChronological(Float64List outBuffer) {
    final count = outBuffer.length < capacity ? outBuffer.length : capacity;
    if (_totalWritten < capacity) {
      // Buffer not full yet
      for (int i = 0; i < count; i++) {
        outBuffer[i] = _data[i];
      }
    } else {
      // Buffer has wrapped around
      int readIdx = _writeIndex;
      for (int i = 0; i < count; i++) {
        outBuffer[i] = _data[readIdx];
        readIdx = (readIdx + 1) % capacity;
      }
    }
  }

  int get writeIndex => _writeIndex;
  int get totalSamples => _totalWritten;
  Float64List get rawBuffer => _data;
}
