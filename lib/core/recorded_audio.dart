import 'dart:ffi';
import 'dart:typed_data';

@Native<Int32 Function(Pointer<Uint8>, IntPtr, Int32)>(
  symbol: 'orb_has_speech',
  isLeaf: true,
)
external int _hasSpeech(Pointer<Uint8> pcm, int length, int rate);

/// Detects an empty mic input in Orb's 16-bit PCM WAV recordings. Check the
/// actual data chunk: Android and Apple can add different metadata and padding.
bool hasRecordedSignal(Uint8List wav) {
  if (wav.length < 12) return false;
  final bytes = ByteData.sublistView(wav);
  int tag(int at) => bytes.getUint32(at);
  if (tag(0) != 0x52494646 || tag(8) != 0x57415645) return false; // RIFF/WAVE

  var sampleRate = 0;
  for (int at = 12; at + 8 <= wav.length;) {
    final kind = tag(at);
    final size = bytes.getUint32(at + 4, Endian.little);
    final start = at + 8;
    if (size > wav.length - start) return false;
    if (kind == 0x666d7420 && size >= 16) {
      // fmt
      final encoding = bytes.getUint16(start, Endian.little);
      final bits = bytes.getUint16(start + 14, Endian.little);
      final pcm =
          encoding == 1 ||
          (encoding == 0xfffe &&
              size >= 40 &&
              bytes.getUint32(start + 24, Endian.little) == 1);
      if (!pcm || bits != 16) return false;
      sampleRate = bytes.getUint32(start + 4, Endian.little);
    }
    if (kind == 0x64617461 && sampleRate > 0) {
      final pcm = Uint8List.sublistView(wav, start, start + size);
      return _hasSpeech(pcm.address, pcm.length, sampleRate) == 1;
    }
    at = start + size + size % 2;
  }
  return false;
}
