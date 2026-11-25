import 'package:material_ui/material_ui.dart';

import '../core/constants.dart';
import '../models/device_model.dart';
import '../models/dixell_model.dart';
import '../services/auth_service.dart';
import '../services/mqtt_service.dart';

/// Экран контроллера Dixell XR60CX.
///
/// Мониторинг (температуры, уставка, состояние, аварии) доступен
/// всем пользователям. Панель управления (уставка, вкл/выкл)
/// отображается только для admin.
class DixellDetailsPage extends StatefulWidget {
  final DeviceModel device;
  const DixellDetailsPage({super.key, required this.device});

  @override
  State<DixellDetailsPage> createState() => _DixellDetailsPageState();
}

class _DixellDetailsPageState extends State<DixellDetailsPage> {
  @override
  void initState() {
    super.initState();
    MqttService.instance.addListener(_onUpdate);
  }

  @override
  void dispose() {
    MqttService.instance.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  DixellState? get _state =>
      MqttService.instance.dixellStates[widget.device.deviceId];

  bool get _isOnline {
    final statuses = MqttService.instance.deviceStatuses;
    final id = widget.device.deviceId;
    final status = statuses[id] ??
        statuses[id.toUpperCase()] ??
        statuses[id.toLowerCase()];
    return status == DeviceStatus.online;
  }

  bool get _isAdmin => AuthService.instance.isAdmin;

  bool _savingSetpoint = false;

  Future<void> _editSetpoint(DixellState state) async {
    final controller = TextEditingController(
      text: state.sp == null ? '' : (state.sp! / 10).toStringAsFixed(1),
    );
    final result = await showDialog<double>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: cardColor,
          title: const Text('Уставка, °C'),
          content: TextField(
            controller: controller,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true, signed: true),
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'от -20.0 до 10.0 (стенд)',
              suffixText: '°C',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Отмена'),
            ),
            ElevatedButton(
              onPressed: () {
                final value = double.tryParse(
                  controller.text.replaceAll(',', '.'),
                );
                Navigator.of(dialogContext).pop(value);
              },
              child: const Text('Установить'),
            ),
          ],
        );
      },
    );
    if (result == null || !mounted || !_isAdmin || _savingSetpoint) return;
    setState(() => _savingSetpoint = true);
    final ack = await MqttService.instance.setDixellSetpoint(widget.device.deviceId, result);
    if (!mounted) return;
    setState(() => _savingSetpoint = false);
    final ok = ack['ok'] == true;
    final actual = ack['raw'];
    final reason = ack['reason'];
    final message = ok && actual is int
        ? 'Уставка подтверждена: ${DixellState.formatTenths(actual)} °C'
        : reason == 'unavailable' || reason == 'precision' || reason == 'out_of_bench_range'
            ? 'Недоступно или значение вне -20…10 °C (шаг 0.1).'
            : 'Запись не подтверждена. Проверьте уставку на Dixell.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final online = _isOnline;

    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async => MqttService.instance.refresh(),
          color: accentColor,
          backgroundColor: cardColor,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            children: [
              _buildHeader(online),
              const SizedBox(height: 16),
              if (state == null)
                const _Placeholder()
              else if (!online)
                const Text('Свежих данных нет. Последние показания скрыты.',
                    style: TextStyle(color: secondaryText))
              else ...[
                if (state.benchMode) ...[
                  const Text('Стенд: датчики и нагрузка не подключены.',
                      style: TextStyle(color: secondaryText)),
                  const SizedBox(height: 12),
                ] else if (!state.mapVerified) ...[
                  const Text('Показания датчиков требуют сверки с дисплеем.',
                      style: TextStyle(color: Colors.orangeAccent)),
                  const SizedBox(height: 12),
                ],
                _buildTemperatureCard(state),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _InfoCard(
                        title: 'Испаритель',
                        value: state.probe2Text,
                        unit: '°C',
                        icon: Icons.ac_unit,
                        iconColor: Colors.blueAccent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _InfoCard(
                        title: 'Уставка',
                        value: state.setpointText,
                        unit: '°C',
                        icon: Icons.tune,
                        iconColor: Colors.orangeAccent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildStatusCard(state),
                const SizedBox(height: 12),
                _buildAlarmCard(state),
                if (_isAdmin) ...[
                  const SizedBox(height: 12),
                  if (state.benchMode)
                    _buildControlCard(state)
                  else
                    const Text('Управление доступно только после индивидуальной проверки.',
                        style: TextStyle(color: secondaryText)),
                ],
                const SizedBox(height: 12),
                _buildTechCard(state),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool online) {
    return Row(
      children: [
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_ios_new,
              color: secondaryText, size: 20),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.device.name,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    Icons.circle,
                    size: 9,
                    color: online ? accentColor : Colors.redAccent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    online ? 'В сети' : 'Не в сети',
                    style: const TextStyle(
                      color: secondaryText,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Text(
            'DIXELL XR60CX',
            style: TextStyle(
              color: Colors.blueAccent,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTemperatureCard(DixellState state) {
    final t1 = state.benchMode ? null : state.t1;
    final alarmColor =
        state.mapVerified && state.hasAlarm ? Colors.redAccent : accentColor;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.thermostat, color: accentColor, size: 18),
              SizedBox(width: 8),
              Text(
                'Температура воздуха (P1)',
                style: TextStyle(color: secondaryText, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                state.probe1Text,
                style: TextStyle(
                  fontSize: 46,
                  fontWeight: FontWeight.bold,
                  color: t1 == null ? secondaryText : alarmColor,
                ),
              ),
              const SizedBox(width: 6),
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '°C',
                  style: TextStyle(fontSize: 20, color: secondaryText),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard(DixellState state) {
    final on = state.on;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          Icon(
            on == true ? Icons.play_circle : Icons.pause_circle,
            color: on == true ? accentColor : secondaryText,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Состояние контроллера',
                  style: TextStyle(color: secondaryText, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  on == null || !state.mapVerified ? 'Не подтверждено' : (on ? 'Работает' : 'Остановлен'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: on == true ? accentColor : Colors.white,
                  ),
                ),
              ],
            ),
          ),
          if (!state.benchMode && (state.t3 ?? state.t4) != null)
            Text(
              'P3: ${state.probe3Text}  P4: ${state.probe4Text}',
              style: const TextStyle(color: secondaryText, fontSize: 11),
            ),
        ],
      ),
    );
  }

  Widget _buildAlarmCard(DixellState state) {
    if (state.alm == null || !state.mapVerified) {
      return const Text('Состояние аварий не подтверждено',
          style: TextStyle(color: Colors.orangeAccent));
    }
    final alarms = state.alarms;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                alarms.isEmpty
                    ? Icons.check_circle_outline
                    : Icons.warning_amber,
                color: alarms.isEmpty ? accentColor : Colors.redAccent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                alarms.isEmpty ? 'Аварий нет' : 'Активные аварии',
                style: TextStyle(
                  color: alarms.isEmpty ? accentColor : Colors.redAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          if (alarms.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final alarm in alarms)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        color: Colors.redAccent, size: 14),
                    const SizedBox(width: 8),
                    Text(alarm, style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildControlCard(DixellState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accentColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.admin_panel_settings_outlined,
                  color: accentColor, size: 18),
              SizedBox(width: 8),
              Text(
                'Управление (admin)',
                style: TextStyle(
                  color: accentColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _savingSetpoint || !MqttService.instance.canControlDixell(widget.device.deviceId)
                ? null : () => _editSetpoint(state),
            icon: const Icon(Icons.tune, size: 18),
            label: Text(
              _savingSetpoint ? 'Ожидаем подтверждение…' : state.sp == null
                  ? 'Задать уставку'
                  : 'Изменить уставку (${state.setpointText} °C)',
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: accentColor,
              side: BorderSide(color: accentColor.withValues(alpha: 0.4)),
            ),
          ),
          const SizedBox(height: 10),
          const Text('Стендовый диапазон: -20…10 °C. Вкл/выкл — после сверки катушки 513.',
              style: TextStyle(color: secondaryText, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildTechCard(DixellState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Техническая информация',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 12),
          _techRow('P1 / P2 raw', '${state.t1 ?? "—"} / ${state.t2 ?? "—"}'),
          _techRow('P3 / P4 raw', '${state.t3 ?? "—"} / ${state.t4 ?? "—"}'),
          _techRow('SP raw (0x035F)', '${state.sp ?? "—"}'),
          _techRow('Uptime', '${state.uptimeMs ~/ 1000} с'),
          _techRow('Wi-Fi RSSI', '${state.rssi} dBm'),
          _techRow('Катушки 512..543',
              state.coils == null ? '—' : '0x${state.coils!.toRadixString(16).toUpperCase()}'),
          _techRow(
            'Обновлено',
            '${state.receivedAt.hour.toString().padLeft(2, '0')}:'
                '${state.receivedAt.minute.toString().padLeft(2, '0')}:'
                '${state.receivedAt.second.toString().padLeft(2, '0')}',
          ),
        ],
      ),
    );
  }

  Widget _techRow(String title, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title,
              style: const TextStyle(color: secondaryText, fontSize: 12)),
          Text(value, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String title;
  final String value;
  final String unit;
  final IconData icon;
  final Color iconColor;

  const _InfoCard({
    required this.title,
    required this.value,
    required this.unit,
    required this.icon,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 16),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  title,
                  style:
                      const TextStyle(color: secondaryText, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style:
                    const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 4),
              Text(unit,
                  style: const TextStyle(
                      color: secondaryText, fontSize: 13)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Column(
        children: [
          Icon(Icons.wifi_tethering_error_outlined,
              color: secondaryText, size: 36),
          SizedBox(height: 12),
          Text(
            'Данных пока нет',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          SizedBox(height: 6),
          Text(
            'Ожидаем первый пакет от ESP32-моста Dixell.',
            style: TextStyle(color: secondaryText, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
