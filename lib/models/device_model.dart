import 'package:material_ui/material_ui.dart';

/// Тип подключенного контроллера.
enum DeviceKind { bm, dixell }

/// Тип устройства по идентификатору: DX.. — Dixell XR60CX, остальное — BM.
DeviceKind deviceKindOf(String deviceId) =>
    deviceId.toUpperCase().startsWith('DX')
        ? DeviceKind.dixell
        : DeviceKind.bm;

/// Отображаемое имя устройства по его идентификатору.
String deviceDisplayName(String deviceId) {
  switch (deviceId.toUpperCase()) {
    case 'BM01':
      return 'Камера газации №1';
    case 'BM02':
      return 'Камера газации №2';
    case 'BM03':
      return 'Камера газации №3';
    case 'DX01':
      return 'Камера хранения №1';
    case 'DX02':
      return 'Камера хранения №2';
    case 'DX03':
      return 'Камера хранения №3';
    case 'DX04':
      return 'Камера хранения №4';
    case 'DX05':
      return 'Камера хранения №5';
    case 'DX06':
      return 'Камера хранения №6';
    default:
      return deviceKindOf(deviceId) == DeviceKind.dixell
          ? 'Dixell $deviceId'
          : 'BM Controller $deviceId';
  }
}

/// Все устройства, которые должны отображаться на экране «Обзор».
const List<String> kAllDeviceIds = [
  'BM01',
  'BM02',
  'BM03',
  'DX01',
  'DX02',
  'DX03',
  'DX04',
  'DX05',
  'DX06',
];

/// Статус подключения устройства.
enum DeviceStatus { online, offline, waiting }

/// Модель устройства BM.
class DeviceModel {
  final String deviceId;
  final String name;
  final DeviceStatus status;

  const DeviceModel({
    required this.deviceId,
    required this.name,
    this.status = DeviceStatus.waiting,
  });

  /// Текст статуса для отображения в UI.
  String get statusLabel => switch (status) {
        DeviceStatus.online => 'В сети',
        DeviceStatus.offline => 'Не в сети',
        DeviceStatus.waiting => 'Ожидание подключения',
      };

  /// Цвет индикатора статуса.
  Color get statusColor => switch (status) {
        DeviceStatus.online => const Color(0xFF39D5A0),
        DeviceStatus.offline => Colors.redAccent,
        DeviceStatus.waiting => Colors.orangeAccent,
      };
}
