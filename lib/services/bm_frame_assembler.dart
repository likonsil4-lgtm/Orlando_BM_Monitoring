import 'bm_decoder.dart';

/// Восстановление кадров RS232 из произвольных MQTT-фрагментов ESP32.
/// Каждый экземпляр обслуживает только один BM. Кадр: 20 20 + 19 байт.
class BmFrameAssembler {
  final List<int> _buffer = [];
  int? _lastSequence;
  int? _lastUptime;

  void reset() {
    _buffer.clear();
    _lastSequence = null;
    _lastUptime = null;
  }

  List<String> addChunk({
    required String hex,
    required int length,
    required int sequence,
    required int uptimeMs,
  }) {
    // Не склеиваем части через пропущенный пакет или перезапуск ESP32.
    if (_lastSequence == sequence && _lastUptime == uptimeMs) return [];
    final previous = _lastSequence;
    final lastUptime = _lastUptime;
    if ((previous != null && sequence != ((previous + 1) & 0xffffffff)) ||
        (lastUptime != null && uptimeMs < lastUptime)) {
      _buffer.clear();
    }
    _lastSequence = sequence;
    _lastUptime = uptimeMs;

    if (length <= 0 || hex.length != length * 2 ||
        !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
      _buffer.clear();
      return [];
    }
    for (var i = 0; i < hex.length; i += 2) {
      _buffer.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }

    final frames = <String>[];
    while (_buffer.isNotEmpty) {
      if (_buffer.first != 0x20 ||
          (_buffer.length >= 2 && _buffer[1] != 0x20)) {
        _buffer.removeAt(0);
        continue;
      }
      if (_buffer.length < 21) break;
      final candidate = _buffer.sublist(0, 21);
      if (BmDecoder.instance.verifyChecksum(candidate.sublist(2))) {
        frames.add(BmDecoder.instance.toHex(candidate));
        _buffer.removeRange(0, 21);
      } else {
        // Сдвигаемся на один байт, чтобы не потерять следующий заголовок.
        _buffer.removeAt(0);
      }
    }
    return frames;
  }
}
