/// Модель состояния контроллера Dixell XR60CX.
///
/// Данные приходят от ESP32-моста (Modbus RTU → MQTT) в топике
/// dixell/<id>/state в виде JSON:
/// {
///   "device": "DX01",
///   "type": "dixell",
///   "t1": 171,        // датчик P1 (термостат), десятые доли °C
///   "t2": -42,        // датчик P2 (испаритель)
///   "t3": null,       // датчик P3
///   "t4": null,       // датчик P4 (HOT KEY)
///   "sp": 250,        // уставка, десятые доли °C (null — не удалось прочитать)
///   "on": true,       // контроллер включён
///   "alm": 0,         // битовая маска аварий
///   "coils": 12345,   // сырые дискретные 512..543 (для калибровки)
///   "uptime_ms": 123456,
///   "rssi": -55
/// }
class DixellState {
  final String deviceId;

  /// Датчики температуры, десятые доли °C. null — датчика нет / ошибка.
  final int? t1;
  final int? t2;
  final int? t3;
  final int? t4;

  /// Уставка, десятые доли °C.
  final int? sp;

  /// Контроллер включён (катушка 513).
  final bool? on;

  /// Маска аварий: бит 0 — высокая t°, 1 — низкая t°, 2 — ошибка датчика,
  /// 3 — внешний вход, 4 — EEPROM, 15 — любая авария.
  final int? alm;

  /// Сырые катушки 512..543 (бит 0 = катушка 512).
  final int? coils;

  /// Карта регистров подтверждена на оборудовании.
  final bool mapVerified;
  final bool benchMode;
  final bool setpointControl;
  final bool hasControlMetadata;
  final int commandToken;
  final String firmwareVersion;

  final int uptimeMs;
  final int rssi;

  final DateTime receivedAt;

  const DixellState({
    required this.deviceId,
    this.t1,
    this.t2,
    this.t3,
    this.t4,
    this.sp,
    this.on,
    this.alm,
    this.coils,
    this.mapVerified = false,
    this.benchMode = false,
    this.setpointControl = false,
    this.hasControlMetadata = false,
    this.commandToken = 0,
    this.firmwareVersion = 'unknown',
    this.uptimeMs = 0,
    this.rssi = 0,
    required this.receivedAt,
  });

  factory DixellState.fromJson(Map<String, dynamic> json) {
    int? tenths(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is num) return v.toInt();
      return null;
    }

    return DixellState(
      deviceId: (json['device'] ?? 'UNKNOWN').toString(),
      t1: tenths('t1'),
      t2: tenths('t2'),
      t3: tenths('t3'),
      t4: tenths('t4'),
      sp: tenths('sp'),
      on: json['on'] is bool ? json['on'] as bool : null,
      alm: tenths('alm'),
      coils: tenths('coils'),
      mapVerified: json['map_verified'] == true,
      benchMode: json['bench_mode'] == true,
      setpointControl: json['setpoint_control'] == true,
      hasControlMetadata: json.containsKey('setpoint_control') ||
          json.containsKey('command_token') || json.containsKey('bench_mode'),
      commandToken: tenths('command_token') ?? 0,
      firmwareVersion: (json['fw'] ?? 'unknown').toString(),
      uptimeMs: (json['uptime_ms'] as num?)?.toInt() ?? 0,
      rssi: (json['rssi'] as num?)?.toInt() ?? 0,
      receivedAt: DateTime.now(),
    );
  }

  /// Форматирование десятых долей: 171 → «17.1», -42 → «-4.2».
  static String formatTenths(int? value) {
    if (value == null) return '—';
    final sign = value < 0 ? '-' : '';
    final abs = value.abs();
    return '$sign${abs ~/ 10}.${abs % 10}';
  }

  String get probe1Text => formatTenths(t1);
  String get probe2Text => formatTenths(t2);
  String get probe3Text => formatTenths(t3);
  String get probe4Text => formatTenths(t4);
  String get setpointText => formatTenths(sp);

  /// Список активных аварий (человекочитаемые названия).
  List<String> get alarms {
    const names = <int, String>{
      0: 'Высокая температура',
      1: 'Низкая температура',
      2: 'Ошибка датчика',
      3: 'Внешний вход',
      4: 'Сбой EEPROM',
      15: 'Авария',
    };
    final mask = alm;
    if (mask == null) return [];
    return [
      for (final entry in names.entries)
        if ((mask >> entry.key) & 1 == 1) entry.value,
    ];
  }

  bool get hasAlarm => alm != null && alm != 0;
}
