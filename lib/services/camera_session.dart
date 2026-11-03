import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';

import '../models/camera_config.dart';

enum CameraStatus {
  /// Abriendo el stream por primera vez o reconectando.
  connecting,

  /// Llegan cuadros de video.
  connected,

  /// Sin video: error, stream terminado o imagen congelada.
  disconnected,

  /// El usuario pausó la reproducción a propósito (no dispara alarma).
  paused,
}

/// Mantiene vivo el reproductor VLC de una cámara y vigila si llega video.
///
/// Se considera que hay video cuando VLC está en estado `playing` y la
/// posición de reproducción avanza. Si deja de avanzar (stream congelado),
/// VLC reporta error/fin, o queda bufferizando, la cámara pasa a
/// [CameraStatus.disconnected] y se intenta reconectar periódicamente.
class CameraSession extends ChangeNotifier {
  CameraSession(this._config, {bool startMuted = false}) : _muted = startMuted {
    controller = _buildController();
    controller.addListener(_onPlayerEvent);
    _watchdog = Timer.periodic(_tick, (_) => _evaluate());
  }

  static const Duration _tick = Duration(milliseconds: 500);

  /// Tiempo sin avance de la posición para considerar el video congelado.
  static const Duration _stallThreshold = Duration(milliseconds: 2500);

  /// Cada cuánto reintentar abrir el stream mientras está caído.
  static const Duration _reconnectEvery = Duration(seconds: 6);

  CameraConfig _config;
  CameraConfig get config => _config;

  late VlcPlayerController controller;
  Timer? _watchdog;

  CameraStatus _status = CameraStatus.connecting;
  CameraStatus get status => _status;

  bool _userPaused = false;
  bool get userPaused => _userPaused;

  bool _muted;
  bool get muted => _muted;

  /// Momento desde el que no llega video (null si hay video o está pausada).
  DateTime? _noVideoSince = DateTime.now();
  DateTime? get noVideoSince => _noVideoSince;

  Duration _lastPosition = Duration.zero;
  DateTime _lastProgressAt = DateTime.now();
  bool _positionEverAdvanced = false;
  DateTime _lastReconnectAt = DateTime.now();
  bool _disposed = false;

  String? _lastError;
  String? get lastError => _lastError;

  /// Tiempo continuo sin video (cero si hay video o el usuario pausó).
  Duration get timeWithoutVideo {
    final since = _noVideoSince;
    if (since == null || _userPaused) return Duration.zero;
    return DateTime.now().difference(since);
  }

  VlcPlayerController _buildController() {
    final caching = _config.networkCachingMs.clamp(50, 5000);
    return VlcPlayerController.network(
      _config.streamUrl,
      hwAcc: HwAcc.full,
      autoPlay: true,
      autoInitialize: true,
      // Seguir recibiendo video y audio con la pantalla apagada o la app en
      // segundo plano: así el monitor y la alarma no se interrumpen.
      allowBackgroundPlayback: true,
      options: VlcPlayerOptions(
        advanced: VlcAdvancedOptions([
          VlcAdvancedOptions.networkCaching(caching),
          VlcAdvancedOptions.liveCaching(caching),
          VlcAdvancedOptions.clockJitter(0),
          VlcAdvancedOptions.clockSynchronization(0),
        ]),
        rtp: VlcRtpOptions([
          VlcRtpOptions.rtpOverRtsp(_config.useTcp),
        ]),
        video: VlcVideoOptions([
          VlcVideoOptions.dropLateFrames(true),
          VlcVideoOptions.skipFrames(true),
        ]),
        extras: [
          '--rtsp-frame-buffer-size=500000',
        ],
      ),
    );
  }

  PlayingState? _lastState;

  void _onPlayerEvent() {
    final v = controller.value;
    if (v.playingState != _lastState) {
      _lastState = v.playingState;
      // VLC olvida el volumen al reabrir el medio: lo reaplicamos al arrancar.
      if (v.playingState == PlayingState.playing) unawaited(_applyVolume());
    }
    if (v.hasError && v.errorDescription.isNotEmpty) {
      _lastError = v.errorDescription;
    }
    if (v.position != _lastPosition) {
      if (v.position > _lastPosition) {
        _positionEverAdvanced = true;
        _lastProgressAt = DateTime.now();
      }
      _lastPosition = v.position;
    }
  }

  bool get _receivingVideo {
    final v = controller.value;
    if (!v.isInitialized || v.hasError) return false;
    if (v.playingState != PlayingState.playing) return false;
    // Algunos streams en vivo no reportan posición; en ese caso confiamos en
    // el estado `playing`. Si alguna vez avanzó, exigimos que siga avanzando.
    if (!_positionEverAdvanced) return true;
    return DateTime.now().difference(_lastProgressAt) < _stallThreshold;
  }

  void _evaluate() {
    if (_disposed) return;
    final previous = _status;
    final now = DateTime.now();

    if (_userPaused) {
      _status = CameraStatus.paused;
      _noVideoSince = null;
    } else if (_receivingVideo) {
      _status = CameraStatus.connected;
      _noVideoSince = null;
    } else {
      _noVideoSince ??= now;
      final state = controller.value.playingState;
      final dead = controller.value.hasError ||
          state == PlayingState.error ||
          state == PlayingState.ended ||
          state == PlayingState.stopped;
      final lostFor = now.difference(_noVideoSince!);
      _status = (lostFor < const Duration(seconds: 5) && !dead)
          ? CameraStatus.connecting
          : CameraStatus.disconnected;

      final wantsReconnect = (dead || lostFor >= const Duration(seconds: 5)) &&
          now.difference(_lastReconnectAt) >= _reconnectEvery;
      if (wantsReconnect) {
        _lastReconnectAt = now;
        unawaited(_reconnect());
      }
    }

    // Notificamos en cada tick mientras no hay video para refrescar el contador.
    if (previous != _status || _noVideoSince != null) notifyListeners();
  }

  Future<void> _reconnect() async {
    if (!controller.value.isInitialized) return;
    _positionEverAdvanced = false;
    _lastPosition = Duration.zero;
    _lastProgressAt = DateTime.now();
    try {
      await controller.stop();
      await controller.setMediaFromNetwork(
        _config.streamUrl,
        hwAcc: HwAcc.full,
        autoPlay: true,
      );
      await _applyVolume();
    } catch (e) {
      _lastError = e.toString();
      debugPrint('[${_config.name}] reconexión fallida: $e');
    }
  }

  Future<void> _applyVolume() async {
    if (!controller.value.isInitialized) return;
    try {
      await controller.setVolume(_muted ? 0 : 100);
    } catch (e) {
      debugPrint('[${_config.name}] no se pudo ajustar el volumen: $e');
    }
  }

  Future<void> togglePlayPause() async {
    if (!controller.value.isInitialized) return;
    _userPaused = !_userPaused;
    if (_userPaused) {
      await controller.pause();
    } else {
      // Al reanudar un stream en vivo conviene reabrirlo para no ver
      // cuadros viejos acumulados en el buffer.
      _noVideoSince = DateTime.now();
      _lastReconnectAt = DateTime.now();
      await _reconnect();
    }
    _evaluate();
    notifyListeners();
  }

  Future<void> toggleMute() async {
    _muted = !_muted;
    await _applyVolume();
    notifyListeners();
  }

  Future<void> setMuted(bool value) async {
    if (_muted == value) return;
    _muted = value;
    await _applyVolume();
    notifyListeners();
  }

  /// Actualiza la configuración. Si cambió el stream, lo reabre.
  Future<void> updateConfig(CameraConfig newConfig) async {
    final mustReopen = !_config.sameStreamAs(newConfig);
    _config = newConfig;
    notifyListeners();
    if (mustReopen) {
      // Las opciones de VLC (caché, TCP) solo se aplican al crear el
      // controlador; la pantalla recrea el widget al detectar el cambio.
      final old = controller;
      old.removeListener(_onPlayerEvent);
      controller = _buildController();
      controller.addListener(_onPlayerEvent);
      _positionEverAdvanced = false;
      _lastState = null;
      _noVideoSince = DateTime.now();
      _lastReconnectAt = DateTime.now();
      _userPaused = false;
      notifyListeners();
      // Desechamos el viejo después de que el árbol de widgets lo suelte.
      Future.delayed(const Duration(seconds: 1), () => old.dispose());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _watchdog?.cancel();
    controller.removeListener(_onPlayerEvent);
    controller.dispose();
    super.dispose();
  }
}
