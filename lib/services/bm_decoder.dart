import 'package:flutter/foundation.dart';

/// Единый символ индикатора (одно знакоместо).
class BmDigit {
  /// Символ для показа: '0'..'9', '.', или набор сегментов вида "{AEFG}" для
  /// нестандартных комбинаций, или null если знакоместо пустое (0xFF).
  final String? char;

  /// Сегменты, которые реально горят (A..G + H = точка).
  final Set<String> segments;

  /// Точка (сегмент H) горит.
  final bool dot;

  /// Сегмент мигает (по маске мигания).
  final bool blinking;

  const BmDigit({
    required this.char,
    required this.segments,
    required this.dot,
    required this.blinking,
  });

  bool get blank => char == null && segments.isEmpty && !dot;
}

/// Расшифрованный 19-байтный кадр BM V57x2.
///
/// Раскладка ПОДТВЕРЖДЕНА сверкой с руководством (стр. 28–29) и по факту
/// у стоящего у контроллера наблюдателя (старотовых байт в потоке нет,
/// байт N руководства = байт N-3 здесь):
///   [0,1]    знакоместа 1,2   — индикатор РЕЖИМА (слева): "GS", "Pr"...
///   [2..5]   знакоместа 7..10 — индикатор ТЕМПЕРАТУРЫ (справа): " 17.1"
///   [6]      линейка датчиков температуры (бит0 = светодиод 1, 0 = зажжён)
///   [7]      линейка дней программы       (бит0 = светодиод 1, 0 = зажжён)
///   [8]      маска мигания сегментов знакоместа 1 (1 = мигает)
///   [9]      маска мигания сегментов знакоместа 2
///   [10]     маска мигания светодиодов датчиков
///   [11]     маска мигания светодиодов дней (мигает ТЕКУЩИЙ день)
///   [12..15] знакоместа 3..6 — «Clock of Program» (центр), ПЕРЕДАЮТСЯ
///            справа налево: читаем [15],[14],[13],[12] → "01.34"
///   [16]     байт агрегатов (0 = ВКЛ, 1 = ВЫКЛ — как в руководстве;
///            исключение: бит0 «Тревога», 0 = тревога активна)
///   [17,18]  контрольная сумма (мл., ст.) — сумма байт 0..16
class BmFrame {
  /// Знакоместа 1,2 (индикатор режима, слева).
  final List<BmDigit> modeDigits;

  /// Знакоместа 7..10 (индикатор температуры, справа).
  final List<BmDigit> tempDigits;

  /// Знакоместа 3..6 (часы программы, центр) — уже в порядке чтения слева
  /// направо (из кадра извлекаются в обратном порядке).
  final List<BmDigit> clockDigits;

  /// Линейка датчиков: true = светодиод зажжён. Индекс 0 = датчик 1.
  final List<bool> sensorLeds;

  /// Линейка дней: true = светодиод зажжён. Индекс 0 = день 1.
  final List<bool> dayLeds;

  /// Маска мигания светодиодов датчиков (бит0 = датчик 1, 1 → мигает).
  final int blinkSensors;

  /// Маска мигания светодиодов дней (бит0 = день 1, 1 → мигает).
  final int blinkDays;

  /// Байт агрегатов (сырой).
  final int relaysByte;

  /// Контрольная сумма сошлась.
  final bool checksumOk;

  const BmFrame({
    required this.modeDigits,
    required this.tempDigits,
    required this.clockDigits,
    required this.sensorLeds,
    required this.dayLeds,
    required this.blinkSensors,
    required this.blinkDays,
    required this.relaysByte,
    required this.checksumOk,
  });

  /// Текст индикатора режима (знакоместа 1,2): "Pr", "GS" и т.п.
  String get modeText {
    final raw = modeDigits
        .map((d) => d.char ?? (d.segments.isEmpty ? '' : '{${d.segments.join()}}'))
        .join();
    return raw.trim();
  }

  /// Режим в человекочитаемом виде, напр. «Газация».
  String? get modeLabel => BmDecoder._modeTable[modeText];

  /// Текст индикатора ТЕМПЕРАТУРЫ (справа), напр. "17.1".
  String get temperatureText => _digitsToText(tempDigits);

  /// Текст индикатора часов программы (центр), напр. "01.34".
  String get clockText => _digitsToText(clockDigits);

  /// Текущий день программы (номер мигающего светодиода), 1..8.
  /// null если ни один день не мигает.
  int? get currentDay {
    for (var i = 0; i < 8; i++) {
      if (((blinkDays >> i) & 1) == 1 && dayLeds[i]) return i + 1;
    }
    // Мигания нет, но горит ровно один день — считаем его текущим.
    final lit = [for (var i = 0; i < 8; i++) if (dayLeds[i]) i + 1];
    if (lit.length == 1) return lit.first;
    return null;
  }

  /// Сколько дней в программе (сколько светодиодов горит).
  int get totalDays => dayLeds.where((l) => l).length;

  static String _digitsToText(List<BmDigit> digits) {
    final buf = StringBuffer();
    for (final d in digits) {
      if (d.blank) {
        buf.write(' ');
      } else if (d.char != null) {
        buf.write(d.char);
        if (d.dot) buf.write('.');
      } else {
        buf.write('{${d.segments.join()}}');
        if (d.dot) buf.write('.');
      }
    }
    return buf.toString().trim();
  }
}

/// Состояние одного агрегата.
class BmRelay {
  final String name;

  /// Для агрегатов: true = включён. Для тревоги: true = тревога активна.
  final bool on;

  /// true для тревожного канала (инверсная логика отображения).
  final bool isAlarm;

  const BmRelay(this.name, this.on, {this.isAlarm = false});
}

class BmDecoder {
  BmDecoder._();
  static final BmDecoder instance = BmDecoder._();

  static const int frameLength = 19;
  static const int relaysIndex = 16;

  /// Калиброванная таблица сегментов: код → символ.
  /// Код = биты A..G (бит0=A … бит6=G), точка (H, бит7) обрабатывается отдельно.
  /// Подтверждена кадром-примером из руководства и живыми кадрами.
  static const Map<int, String> _segmentTable = {
    0x3F: '0',
    0x06: '1',
    0x5B: '2',
    0x4F: '3',
    0x66: '4',
    0x6D: '5',
    0x7D: '6',
    0x07: '7',
    0x7F: '8',
    0x6F: '9',
    0x40: '-', // только средний сегмент
    // Буквы (для индикатора режима и нестандартных символов)
    0x77: 'A', // A,B,C,E,F,G
    0x7C: 'b', // C,D,E,F,G
    0x39: 'C', // A,D,E,F
    0x5E: 'd', // B,C,D,E,G
    0x79: 'E', // A,D,E,F,G
    0x71: 'F', // A,E,F,G
    0x3D: 'G', // A,C,D,E,F
    0x76: 'H', // B,C,E,F,G
    0x38: 'L', // D,E,F
    0x54: 'n', // C,E,G
    0x5C: 'o', // C,D,E,G
    0x73: 'P', // A,B,E,F,G
    0x50: 'r', // E,G
    0x78: 't', // D,E,F,G
    0x3E: 'U', // B,C,D,E,F
    0x6E: 'Y', // B,C,D,F,G
  };

  /// Распознавание режима по первым двум знакоместам (индикатор режима).
  static const Map<String, String> _modeTable = {
    'GS': 'Газация',
    'G5': 'Газация', // S и 5 неотличимы на 7-сегментнике
    'PR': 'Программа',
    'Pr': 'Программа',
    'ST': 'Стоп',
    '5T': 'Стоп',
    'ON': 'Работа',
    '0N': 'Работа',
    'AL': 'Авария',
  };

  /// Проверка контрольной суммы: сумма байт 0..16 == байт17 | байт18<<8.
  bool verifyChecksum(List<int> frame) {
    if (frame.length < frameLength) return false;
    int sum = 0;
    for (var i = 0; i < frameLength - 2; i++) {
      sum += frame[i];
    }
    final crc = frame[frameLength - 2] | (frame[frameLength - 1] << 8);
    return sum == crc;
  }

  BmDigit _decodeDigit(int byte, int blinkMask) {
    const segByBit = ['A', 'B', 'C', 'D', 'E', 'F', 'G'];
    final segments = <String>{};
    var code = 0;
    for (var i = 0; i < 7; i++) {
      final bit = (byte >> i) & 1;
      if (bit == 0) {
        segments.add(segByBit[i]);
        code |= 1 << i;
      }
    }
    final dot = (byte & 0x80) == 0;
    final anyBlink = segments.any((s) {
      final idx = segByBit.indexOf(s);
      return ((blinkMask >> idx) & 1) == 1;
    }) ||
        (dot && ((blinkMask & 0x80) != 0));

    if (byte == 0xFF) {
      return BmDigit(char: null, segments: const {}, dot: false, blinking: anyBlink);
    }
    final known = _segmentTable[code];
    return BmDigit(
      char: known,
      segments: segments,
      dot: dot,
      blinking: anyBlink,
    );
  }

  List<bool> _decodeLeds(int byte) {
    // По руководству и факту: бит0 = светодиод 1, бит7 = светодиод 8.
    // 0 = светодиод зажжён. Проверено: BBh → горят датчики 3 и 7.
    return List.generate(8, (i) => ((byte >> i) & 1) == 0);
  }

  bool _ledBlink(int index, int blinkMask) {
    // Бит0 = светодиод 1; 1 = мигает. Проверено: маска 01h → мигает день 1.
    return ((blinkMask >> index) & 1) == 1;
  }

  /// Декодирует 19-байтный кадр.
  BmFrame decode(List<int> frame) {
    assert(frame.length >= frameLength);
    return BmFrame(
      modeDigits: [
        _decodeDigit(frame[0], frame[8]),
        _decodeDigit(frame[1], frame[9]),
      ],
      tempDigits: [
        _decodeDigit(frame[2], 0),
        _decodeDigit(frame[3], 0),
        _decodeDigit(frame[4], 0),
        _decodeDigit(frame[5], 0),
      ],
      // Знакоместа 3..6 передаются справа налево: порядок чтения — 15,14,13,12.
      // Подтверждено: 99 B0 79 C0 → «01.34» (время работы на табло).
      clockDigits: [
        _decodeDigit(frame[15], 0),
        _decodeDigit(frame[14], 0),
        _decodeDigit(frame[13], 0),
        _decodeDigit(frame[12], 0),
      ],
      sensorLeds: _decodeLeds(frame[6]),
      dayLeds: _decodeLeds(frame[7]),
      blinkSensors: frame[10],
      blinkDays: frame[11],
      relaysByte: frame[relaysIndex],
      checksumOk: verifyChecksum(frame),
    );
  }

  /// Декодирует HEX-строку из 38 символов (19 байт).
  BmFrame? decodeHex(String hex) {
    if (hex.length < 38) return null;
    final bytes = <int>[];
    for (var i = 0; i < 38; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return decode(bytes);
  }

  /// Список агрегатов по руководству: 0 = ВКЛ, 1 = ВЫКЛ.
  /// Биты: 7 Блок.дверей, 6 Газ, 5 Охлаждение, 4 Вентиляция,
  /// 3 Вентилятор воздухоохладителя, 2 Нагрев, 1 резерв, 0 Тревога.
  /// Подтверждено у контроллера: 1Fh → двери+газ+охлаждение вкл,
  /// нагрев/вентиляция/вент.возд. выкл, тревоги нет.
  List<BmRelay> relays(int relaysByte) {
    bool on(int bit) => ((relaysByte >> bit) & 1) == 0;
    return [
      BmRelay('Нагрев', on(2)),
      BmRelay('Вентилятор воздухоохладителя', on(3)),
      BmRelay('Вентиляция', on(4)),
      BmRelay('Охлаждение', on(5)),
      BmRelay('Газ', on(6)),
      BmRelay('Блокировка дверей', on(7)),
      // Тревога: бит=0 — тревога активна, бит=1 — норма.
      BmRelay('Тревога', !on(0), isAlarm: true),
    ];
  }

  bool ledBlink(int index, int blinkMask) => _ledBlink(index, blinkMask);

  /// HEX кадра для отладки.
  String toHex(List<int> frame) =>
      frame.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join();
}
