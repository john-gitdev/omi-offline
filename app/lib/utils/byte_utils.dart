extension ByteUtilsExtension on List<int> {
  int getUint32LittleEndian(int offset) {
    return (this[offset] | (this[offset + 1] << 8) | (this[offset + 2] << 16) | (this[offset + 3] << 24)) >>> 0;
  }
}
