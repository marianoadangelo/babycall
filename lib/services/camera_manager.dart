import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/camera_config.dart';
import 'alarm_service.dart';
import 'camera_session.dart';
import 'monitor_service.dart';

/// Estado global: lista de cámaras, alarma maestra y vigilancia de señal.
class CameraManager extends ChangeNotifier {
  CameraManager({AlarmService? alarm, MonitorService? monitor})
      : _alarm = alarm ?? AlarmService(),
        _monitor = monitor ?? MonitorService();

  static const _prefsCameras = 'cameras_v1';
  static const _prefsAlarm = 'alarm_master_v1';

  /// Segundos sin video antes de disparar la alarma.
  static const Duration lossThreshold = Duration(seconds: 5);

  final AlarmService _alarm;
  final MonitorService _monitor;
  final List<CameraSession> _sessions = [];
  Timer? _monitorTimer;
  SharedPreferences? _prefs;

  List<CameraSession> get sessions => List.unmodifiable(_sessions);

  bool _alarmMasterEnabled = true;
  bool get alarmMasterEnabled => _alarmMasterEnabled;

  /// Cámaras que superaron el umbral de 5 s sin video.
  final Set<String> _lostIds = {};
  bool isLost(String id) => _lostIds.contains(id);
  bool get anyLost => _lostIds.isNotEmpty;

  /// Silenciado manual del sonido actual (se rearma al recuperarse el video).
  bool _snoozed = false;
  bool get snoozed => _snoozed;

  bool get alarmRinging => _alarm.isRinging;

  Future<void> load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (e) {
      // Sin preferencias la app funciona igual, solo no recuerda las cámaras.
      debugPrint('No se pudieron leer las preferencias: $e');
    }
    _alarmMasterEnabled = _prefs?.getBool(_prefsAlarm) ?? true;
    final raw = _prefs?.getString(_prefsCameras);
    if (raw != null && raw.isNotEmpty) {
      try {
        for (final c in CameraConfig.decodeList(raw)) {
          // Solo la primera cámara arranca con audio para no mezclar sonidos.
          _sessions.add(CameraSession(c, startMuted: _sessions.isNotEmpty));
        }
      } catch (e) {
        debugPrint('Configuración de cámaras corrupta, se ignora: $e');
      }
    }
    _monitorTimer = Timer.periodic(
        const Duration(milliseconds: 500), (_) => _checkSignal());
    notifyListeners();
    _syncForegroundService();
  }

  /// Mantiene el servicio en primer plano mientras haya cámaras que vigilar,
  /// con un texto que resume el estado (se ve en la notificación persistente).
  void _syncForegroundService() {
    if (_sessions.isEmpty) {
      unawaited(_monitor.stop());
      return;
    }
    final lostNames = _sessions
        .where((s) => _lostIds.contains(s.config.id))
        .map((s) => s.config.name)
        .toList();
    final String text;
    if (lostNames.isNotEmpty) {
      text = 'Sin video: ${lostNames.join(', ')}';
    } else {
      final n = _sessions.length;
      text = n == 1
          ? 'Vigilando ${_sessions.first.config.name}'
          : 'Vigilando $n cámaras';
    }
    unawaited(_monitor.update(text: text, alarm: lostNames.isNotEmpty));
  }

  Future<void> _save() async {
    await _prefs?.setString(
        _prefsCameras, CameraConfig.encodeList(_sessions.map((s) => s.config).toList()));
  }

  CameraSession? byId(String id) {
    for (final s in _sessions) {
      if (s.config.id == id) return s;
    }
    return null;
  }

  Future<void> addCamera(CameraConfig config) async {
    _sessions.add(CameraSession(config, startMuted: _sessions.isNotEmpty));
    notifyListeners();
    _syncForegroundService();
    await _save();
  }

  Future<void> updateCamera(CameraConfig config) async {
    final s = byId(config.id);
    if (s == null) return;
    await s.updateConfig(config);
    notifyListeners();
    _syncForegroundService();
    await _save();
  }

  Future<void> removeCamera(String id) async {
    final s = byId(id);
    if (s == null) return;
    _sessions.remove(s);
    _lostIds.remove(id);
    notifyListeners();
    // Damos tiempo a que el widget del reproductor se desmonte.
    Future.delayed(const Duration(milliseconds: 500), s.dispose);
    _syncForegroundService();
    await _save();
    _checkSignal();
  }

  Future<void> setCameraAlarm(String id, bool enabled) async {
    final s = byId(id);
    if (s == null) return;
    await updateCamera(s.config.copyWith(alarmEnabled: enabled));
    _checkSignal();
  }

  Future<void> setAlarmMaster(bool enabled) async {
    _alarmMasterEnabled = enabled;
    await _prefs?.setBool(_prefsAlarm, enabled);
    _checkSignal();
    notifyListeners();
  }

  /// Apaga el sonido que está sonando sin desactivar la vigilancia. Vuelve a
  /// sonar si una cámara se recupera y se cae otra vez.
  Future<void> snooze() async {
    _snoozed = true;
    await _alarm.stop();
    await _monitor.stopVibration();
    notifyListeners();
  }

  /// Solo para pruebas: hace sonar la alarma unos segundos.
  Future<void> testAlarm() async {
    await _alarm.start();
    await _monitor.startVibration();
    notifyListeners();
    await Future.delayed(const Duration(seconds: 3));
    if (!_shouldRing) {
      await _alarm.stop();
      await _monitor.stopVibration();
    }
    notifyListeners();
  }

  bool get _shouldRing {
    if (!_alarmMasterEnabled || _snoozed) return false;
    return _sessions.any((s) => _lostIds.contains(s.config.id) && s.config.alarmEnabled);
  }

  void _checkSignal() {
    var changed = false;
    for (final s in _sessions) {
      final lost = s.timeWithoutVideo >= lossThreshold;
      final id = s.config.id;
      if (lost && _lostIds.add(id)) changed = true;
      if (!lost && _lostIds.remove(id)) changed = true;
    }
    if (_lostIds.isEmpty && _snoozed) {
      _snoozed = false;
      changed = true;
    }

    final ring = _shouldRing;
    if (ring && !_alarm.isRinging) {
      unawaited(_alarm.start());
      unawaited(_monitor.startVibration());
      changed = true;
    } else if (!ring && _alarm.isRinging) {
      unawaited(_alarm.stop());
      unawaited(_monitor.stopVibration());
      changed = true;
    }
    if (changed) {
      _syncForegroundService();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _monitorTimer?.cancel();
    unawaited(_monitor.stopVibration());
    unawaited(_monitor.stop());
    for (final s in _sessions) {
      s.dispose();
    }
    _alarm.dispose();
    super.dispose();
  }
}
