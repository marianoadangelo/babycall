import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Puente con el código nativo de Android: servicio en primer plano (para
/// que Android no mate la app con la pantalla apagada) y vibración de alarma.
class MonitorService {
  static const _channel = MethodChannel('com.babycall.baby_call/monitor');

  String? _lastText;
  bool? _lastAlarm;
  bool _running = false;

  /// Arranca o actualiza la notificación persistente del servicio.
  Future<void> update({required String text, required bool alarm}) async {
    if (_running && text == _lastText && alarm == _lastAlarm) return;
    _lastText = text;
    _lastAlarm = alarm;
    _running = true;
    await _call('startService', {'text': text, 'alarm': alarm});
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _lastText = null;
    _lastAlarm = null;
    await _call('stopService');
  }

  Future<void> startVibration() => _call('startVibration');

  Future<void> stopVibration() => _call('stopVibration');

  Future<void> _call(String method, [Map<String, Object?>? args]) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // Tests o plataformas sin la parte nativa: se ignora.
    } catch (e) {
      debugPrint('MonitorService.$method falló: $e');
    }
  }
}
