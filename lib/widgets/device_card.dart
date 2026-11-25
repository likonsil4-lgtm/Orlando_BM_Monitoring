import 'package:material_ui/material_ui.dart';

import '../core/constants.dart';
import '../models/device_model.dart';
import '../screens/device_details_page.dart';
import '../screens/dixell_details_page.dart';
import '../models/dixell_model.dart';
import '../services/mqtt_service.dart';

class DeviceCard extends StatelessWidget {
  final DeviceModel device;

  const DeviceCard({
    super.key,
    required this.device,
  });

  /// Текущая температура для Dixell-камер (если данные уже приходили).
  String? get _temperatureText {
    if (device.status != DeviceStatus.online ||
        deviceKindOf(device.deviceId) != DeviceKind.dixell) return null;
    final state = MqttService.instance.dixellStates[device.deviceId];
    final t1 = state?.t1;
    if (t1 == null || state?.mapVerified != true) return null;
    return '${DixellState.formatTenths(t1)} °C';
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        final page = deviceKindOf(device.deviceId) == DeviceKind.dixell
            ? DixellDetailsPage(device: device)
            : DeviceDetailsPage(device: device);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => page),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(17),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.05),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(
                Icons.memory,
                color: Colors.blueAccent,
                size: 26,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    device.deviceId,
                    style: const TextStyle(
                      color: secondaryText,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      Icon(
                        Icons.circle,
                        color: device.statusColor,
                        size: 9,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        device.statusLabel,
                        style: const TextStyle(
                          color: secondaryText,
                          fontSize: 11,
                        ),
                      ),
                      if (_temperatureText != null) ...[
                        const SizedBox(width: 10),
                        Icon(
                          Icons.thermostat,
                          color: Colors.orangeAccent,
                          size: 12,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          _temperatureText!,
                          style: const TextStyle(
                            color: secondaryText,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: secondaryText),
          ],
        ),
      ),
    );
  }
}
