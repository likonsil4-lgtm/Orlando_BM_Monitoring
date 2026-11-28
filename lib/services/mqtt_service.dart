import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../models/device_model.dart';
import '../models/dixell_model.dart';
import 'notification_service.dart';
import 'bm_frame_assembler.dart';

/// Один сырый пакет, полученный от ESP32.
class RawPacket {
  /// Идентификатор устройства (например, «BM01»).
  final String deviceId;

  /// Порядковый номер пакета от устройства.
  final int sequence;

  /// Аптайм устройства в миллисекундах на момент отправки.
  final int uptimeMs;

  /// Длина пакета в байтах.
  final int length;

  /// Сырые данные в HEX.
  final String hex;

  /// Время получения пакета приложением.
  final DateTime receivedAt;

  const RawPacket({
    required this.deviceId,
    required this.sequence,
    required this.uptimeMs,
    required this.length,
    required this.hex,
    required this.receivedAt,
  });

  factory RawPacket.fromEsp32Json(Map<String, dynamic> json) {
    return RawPacket(
      deviceId: (json['device'] ?? 'UNKNOWN').toString(),
      sequence: (json['seq'] as num?)?.toInt() ?? 0,
      uptimeMs: (json['uptime_ms'] as num?)?.toInt() ?? 0,
      length: (json['length'] as num?)?.toInt() ?? 0,
      hex: (json['hex'] ?? '').toString(),
      receivedAt: DateTime.now(),
    );
  }
}

/// Сервис подключения к MQTT-брокеру (HiveMQ Cloud) и приёма
/// сырых данных от ESP32.
///
/// Топики:
///  - bm/<deviceId>/raw    — сырые HEX-пакеты;
///  - bm/<deviceId>/status — {"device":"..","online":true/false}.
///
/// Подключение устанавливается при старте приложения, при разрыве
/// соединение восстанавливается автоматически.
class MqttService extends ChangeNotifier {
  MqttService._();
  static final MqttService instance = MqttService._();

  /// Запуск сторожа таймаута устройств.
  void startWatchdog() {
    _watchdogTimer ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => _checkDeviceTimeouts(),
    );
  }

  void _checkDeviceTimeouts() {
    final now = DateTime.now();
    var changed = false;

    _lastSeenAt.forEach((deviceId, lastSeen) {
      if (now.difference(lastSeen) <= deviceTimeout) return;
      if (_deviceStatuses[deviceId] == DeviceStatus.offline) return;

      _bmAssemblers.remove(deviceId);
      _deviceStatuses[deviceId] = DeviceStatus.offline;
      NotificationService.instance
          .deviceStatus(deviceId, online: false);
      changed = true;
    });

    // After a fresh broker connection, devices with no live packets also
    // leave the waiting state when the initial observation window expires.
    final connectedAt = lastConnectedAt;
    if (_connected && connectedAt != null &&
        now.difference(connectedAt) > deviceTimeout) {
      for (final id in kAllDeviceIds) {
        if (_lastSeenAt.containsKey(id) ||
            _deviceStatuses[id] == DeviceStatus.offline) continue;
        _deviceStatuses[id] = DeviceStatus.offline;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  // ---- Параметры сервера ----
  static const String host =
      'b7c39db3cd51413696b0b4185988fef9.s1.eu.hivemq.cloud';
  static const int port = 8883;
  static const String username = 'Orlando';
  static const String password = '146010qwW+';

  static const String _rawTopic = 'bm/+/raw';
  static const String _statusTopic = 'bm/+/status';
  static const String _dixellStateTopic = 'dixell/+/state';
  static const String _dixellStatusTopic = 'dixell/+/status';

  MqttServerClient? _client;

  bool _connected = false;
  bool get isConnected => _connected;

  bool _connecting = false;
  bool _manualDisconnect = false;

  /// Последнее время успешного соединения.
  DateTime? lastConnectedAt;

  /// Сырые пакеты, сгруппированные по устройствам.
  final Map<String, List<RawPacket>> _packetsByDevice = {};

  // Сырые MQTT-фрагменты остаются в диагностике; экран BM получает
  // только целые кадры с проверенной контрольной суммой.
  final Map<String, BmFrameAssembler> _bmAssemblers = {};
  final Map<String, List<RawPacket>> _bmFramesByDevice = {};

  Map<String, List<RawPacket>> get bmFramesByDevice =>
      Map.unmodifiable(_bmFramesByDevice);

  /// Последние состояния контроллеров Dixell по устройствам.
  final Map<String, DixellState> _dixellStates = {};

  /// Статусы устройств по статус-топикам.
  final Map<String, DeviceStatus> _deviceStatuses = {};

  /// Время последнего живого пакета raw/state.
  final Map<String, DateTime> _lastSeenAt = {};

  /// Если от устройства нет данных дольше этого — считаем офлайн.
  static const Duration deviceTimeout = Duration(seconds: 40);

  Timer? _watchdogTimer;
  Timer? _reconnectTimer;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updates;

  // Require fresh state and write capability for the addressed Dixell.
  final Map<String, Completer<Map<String, dynamic>>> _setpointAcks = {};
  final Set<String> _usedTokens = {};
  // Original firmware has no command token. Confirm by fresh register readback.
  final Map<String, int> _legacyTargets = {};
  final Map<String, Completer<Map<String, dynamic>>> _legacyWrites = {};

  String? dixellControlBlockReason(String id) {
    id = id.toUpperCase();
    final state = _dixellStates[id];
    final seen = _lastSeenAt[id];
    if (!RegExp(r'^DX0[1-6]$').hasMatch(id)) return 'Неизвестный адрес Dixell';
    if (!_connected) return 'Нет подключения к MQTT';
    if (_deviceStatuses[id] != DeviceStatus.online || seen == null ||
        DateTime.now().difference(seen) > deviceTimeout) {
      return 'Нет свежих данных от контроллера';
    }
    if (state == null || state.sp == null) return 'Уставка не прочитана';
    if (state.hasControlMetadata) {
      if (!state.setpointControl) return 'ESP32 не принимает команды для $id';
      if (state.commandToken == 0) return 'Ожидаем свежую команду от ESP32';
      if (_usedTokens.contains('$id:${state.commandToken}')) {
        return 'Ожидаем обновление данных';
      }
    }
    if (_legacyWrites.containsKey(id)) return 'Ожидаем подтверждение уставки';
    return null;
  }

  bool canControlDixell(String id) => dixellControlBlockReason(id) == null;

  Future<Map<String, dynamic>> setDixellSetpoint(String id, double value) async {
    id = id.toUpperCase();
    if (!value.isFinite || value < -20 || value > 10 ||
        !canControlDixell(id)) return {'ok': false, 'reason': 'unavailable'};
    final raw = (value * 10).round();
    if ((value * 10 - raw).abs() > 0.00001) {
      return {'ok': false, 'reason': 'precision'};
    }
    // The transport token is internal, not a permission or calibration flag.
    final state = _dixellStates[id]!;
    if (!state.hasControlMetadata) {
      return _setLegacyDixellSetpoint(id, raw);
    }
    final token = state.commandToken;
    if (token == 0) return {'ok': false, 'reason': 'firmware_mismatch'};
    final key = '$id:$token';
    if (_setpointAcks.containsKey(key) || _usedTokens.contains(key)) {
      return {'ok': false, 'reason': 'pending'};
    }
    final completer = Completer<Map<String, dynamic>>();
    _setpointAcks[key] = completer;
    final builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode({'action': 'setpoint', 'raw': raw, 'token': token}));
    _usedTokens.add(key);
    if (_usedTokens.length > 128) _usedTokens.remove(_usedTokens.first);
    try {
      _client!.publishMessage('dixell/$id/cmd', MqttQos.atLeastOnce,
          builder.payload!, retain: false);
      notifyListeners();
      return await completer.future.timeout(const Duration(seconds: 30),
          onTimeout: () => {'ok': false, 'reason': 'timeout'});
    } catch (_) {
      return {'ok': false, 'reason': 'send_failed'};
    } finally {
      _setpointAcks.remove(key);
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> _setLegacyDixellSetpoint(String id, int raw) async {
    if (_legacyWrites.containsKey(id)) return {'ok': false, 'reason': 'pending'};
    if (_dixellStates[id]?.sp == raw) return {'ok': true, 'raw': raw};
    final completer = Completer<Map<String, dynamic>>();
    _legacyWrites[id] = completer;
    _legacyTargets[id] = raw;
    final builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode({'action': 'setpoint', 'value': raw / 10}));
    try {
      // No retained command, no automatic retry and no token bypass.
      _client!.publishMessage('dixell/$id/cmd', MqttQos.atMostOnce,
          builder.payload!, retain: false);
      notifyListeners();
      return await completer.future.timeout(const Duration(seconds: 60),
          onTimeout: () => {'ok': false, 'reason': 'timeout'});
    } catch (_) {
      return {'ok': false, 'reason': 'send_failed'};
    } finally {
      _legacyWrites.remove(id);
      _legacyTargets.remove(id);
      notifyListeners();
    }
  }

  Map<String, List<RawPacket>> get packetsByDevice =>
      Map.unmodifiable(_packetsByDevice);

  Map<String, DeviceStatus> get deviceStatuses =>
      Map.unmodifiable(_deviceStatuses);

  Map<String, DixellState> get dixellStates =>
      Map.unmodifiable(_dixellStates);

  List<String> get deviceIds => _packetsByDevice.keys.toList();

  // ================= ПОДКЛЮЧЕНИЕ =================

  Future<void> connect() async {
    startWatchdog();
    if (_connected || _connecting) return;
    _reconnectTimer?.cancel();
    _connecting = true;
    _manualDisconnect = false;
    final clientId = 'BM_Monitor_${DateTime.now().microsecondsSinceEpoch}';
    final client = MqttServerClient.withPort(host, clientId, port);
    _client = client;
    client.secure = true;
    client.keepAlivePeriod = 15;
    // Единственный механизм переподключения — наш таймер.
    client.autoReconnect = false;
    client.onDisconnected = () => _onDisconnected(client);
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .authenticateAs(username, password)
        .startClean();
    notifyListeners();
    try {
      await client.connect();
      if (!identical(_client, client)) {
        client.disconnect();
        return;
      }
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        throw StateError('MQTT not connected');
      }
      _subscribe();
      _connecting = false;
      lastConnectedAt = DateTime.now();
      _setConnected(true);
      NotificationService.instance.serverStatus(connected: true);
    } catch (e) {
      debugPrint('MQTT connect: $e');
      _onDisconnected(client);
      client.disconnect();
    }
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    final client = _client;
    if (client != null) {
      _onDisconnected(client);
      client.disconnect();
    }
  }

  Future<void> checkConnection() async {
    _checkDeviceTimeouts();
    final client = _client;
    if (_connected && client != null &&
        client.connectionStatus?.state == MqttConnectionState.connected) return;
    if (_connecting) return;
    if (client != null) {
      _onDisconnected(client);
      client.disconnect();
    }
    if (!_manualDisconnect) await connect();
  }

  Future<void> refresh() async {
    await checkConnection();
    notifyListeners();
  }

  void _scheduleReconnect() {
    if (_manualDisconnect || (_reconnectTimer?.isActive ?? false)) return;
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (!_connected && !_connecting && !_manualDisconnect) connect();
    });
  }

  void _onDisconnected(MqttServerClient client) {
    if (!identical(_client, client)) return;
    _client = null;
    _connecting = false;
    _updates?.cancel();
    _updates = null;
    final wasConnected = _connected;
    _lastSeenAt.clear();
    _bmAssemblers.clear();
    for (final pending in _setpointAcks.values) {
      if (!pending.isCompleted) pending.complete({'ok': false, 'reason': 'disconnected'});
    }
    for (final pending in _legacyWrites.values) {
      if (!pending.isCompleted) pending.complete({'ok': false, 'reason': 'disconnected'});
    }
    // Нет связи с брокером — доступность устройств не подтверждена.
    for (final id in _deviceStatuses.keys.toList()) {
      _deviceStatuses[id] = DeviceStatus.waiting;
    }
    _setConnected(false);
    if (!wasConnected) notifyListeners();
    if (wasConnected) {
      NotificationService.instance.serverStatus(connected: false);
    }
    _scheduleReconnect();
  }

  void _setConnected(bool value) {
    if (_connected == value) return;
    _connected = value;
    notifyListeners();
  }

  // ================= ПОДПИСКИ =================

  void _subscribe() {
    final client = _client;
    if (client == null) return;

    _updates = client.updates!.listen((events) {
      if (identical(_client, client)) _onMessage(events);
    });
    client
      ..subscribe(_rawTopic, MqttQos.atLeastOnce)
      ..subscribe(_statusTopic, MqttQos.atLeastOnce)
      ..subscribe(_dixellStateTopic, MqttQos.atLeastOnce)
      ..subscribe(_dixellStatusTopic, MqttQos.atLeastOnce)
      ..subscribe('dixell/+/ack', MqttQos.atLeastOnce);

  }

  void _onMessage(List<MqttReceivedMessage<MqttMessage>> events) {
    for (final event in events) {
      final topic = event.topic;
      final message = event.payload as MqttPublishMessage;
      // Retained — снимок из прошлого, не доказательство текущей связи.
      if (message.header?.retain == true) continue;
      final payload = MqttPublishPayload.bytesToStringAsString(
        message.payload.message,
      );

      try {
        final decoded = jsonDecode(payload);
        if (decoded is! Map<String, dynamic>) continue;

        final parts = topic.split('/');
        if (parts.length != 3) continue;
        if (topic == 'dixell/bridge/status') {
          if (decoded['online'] == false) {
            for (final id in kAllDeviceIds.where((id) => id.startsWith('DX'))) {
              _lastSeenAt.remove(id);
              _updateDeviceStatus(id, false);
            }
            notifyListeners();
          }
          continue;
        }
        final id = (decoded['device'] ?? '').toString().toUpperCase();
        if (!kAllDeviceIds.contains(id) || parts[1].toUpperCase() != id ||
            (parts[0] == 'dixell' ? !id.startsWith('DX') :
                parts[0] != 'bm' || !id.startsWith('BM'))) continue;

        if (topic == 'dixell/$id/ack' && decoded['action'] == 'setpoint') {
          final token = decoded['token'];
          final pending = token is int ? _setpointAcks['$id:$token'] : null;
          if (pending != null && !pending.isCompleted) pending.complete(decoded);
        } else if (topic.startsWith('dixell/') &&
            topic.endsWith('/state') &&
            decoded['type'] == 'dixell') {
          _handleDixellState(DixellState.fromJson(decoded));
        } else if (topic.endsWith('/raw') && decoded['type'] == 'raw') {
          _handleRawPacket(RawPacket.fromEsp32Json(decoded));
        } else if (topic.endsWith('/status')) {
          _handleStatusMessage(decoded);
        }
      } catch (_) {
        // Невалидный пакет — игнорируем.
      }
    }
  }

  void _handleRawPacket(RawPacket packet) {
    final deviceId = packet.deviceId.toUpperCase();
    if (!deviceId.startsWith('BM')) return;

    final raw = _packetsByDevice.putIfAbsent(deviceId, () => []);
    raw.add(packet);
    if (raw.length > 200) raw.removeRange(0, raw.length - 200);

    final assembler = _bmAssemblers.putIfAbsent(
        deviceId, () => BmFrameAssembler());
    final completed = assembler.addChunk(
      hex: packet.hex,
      length: packet.length,
      sequence: packet.sequence,
      uptimeMs: packet.uptimeMs,
    );

    if (completed.isNotEmpty) {
      final frames = _bmFramesByDevice.putIfAbsent(deviceId, () => []);
      for (final hex in completed) {
        frames.add(RawPacket(
          deviceId: deviceId,
          sequence: packet.sequence,
          uptimeMs: packet.uptimeMs,
          length: 21,
          hex: hex,
          receivedAt: packet.receivedAt,
        ));
      }
      if (frames.length > 200) frames.removeRange(0, frames.length - 200);
      _lastSeenAt[deviceId] = DateTime.now();
      _updateDeviceStatus(deviceId, true);
    }
    // Неполный пакет не затирает последнее достоверное показание.
    notifyListeners();
  }

  void _handleDixellState(DixellState state) {
    final deviceId = state.deviceId.toUpperCase();
    _dixellStates[deviceId] = state;
    final legacy = _legacyWrites[deviceId];
    if (legacy != null && !legacy.isCompleted && !state.hasControlMetadata &&
        state.sp != null && state.sp == _legacyTargets[deviceId]) {
      legacy.complete({'ok': true, 'raw': state.sp});
    }
    _lastSeenAt[deviceId] = DateTime.now();
    _updateDeviceStatus(deviceId, true);
    notifyListeners();
  }

  void _handleStatusMessage(Map<String, dynamic> json) {
    final deviceId = (json['device'] ?? '').toString().toUpperCase();
    if (deviceId.isEmpty) return;
    // Статус true (в том числе старых BM-мостов) не продлевает жизнь.
    // Только реальный raw/state подтверждает связь. Явный false — сразу offline.
    if (json['online'] != false) return;
    _lastSeenAt.remove(deviceId);
    _bmAssemblers.remove(deviceId);
    _updateDeviceStatus(deviceId, false);
    notifyListeners();
  }

  void _updateDeviceStatus(String deviceId, bool online) {
    final newStatus =
    online ? DeviceStatus.online : DeviceStatus.offline;
    final old = _deviceStatuses[deviceId];

    if (old == newStatus) return;

    // Уведомляем об отключении известного устройства
    // или о новом подключении.
    if ((old == DeviceStatus.online && !online) || online) {
      NotificationService.instance
          .deviceStatus(deviceId, online: online);
    }
    _deviceStatuses[deviceId] = newStatus;
  }

  void clearHistory() {
    _packetsByDevice.clear();
    _bmFramesByDevice.clear();
    _bmAssemblers.clear();
    notifyListeners();
  }
}
