import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Reproduce un sonido de alarma continuo y fuerte por el canal de ALARMA de
/// Android (suena aunque el volumen multimedia esté bajo y respeta el volumen
/// de alarma del teléfono).
class AlarmService {
  final AudioPlayer _player = AudioPlayer(playerId: 'baby_call_alarm');
  bool _ready = false;
  bool _ringing = false;

  bool get isRinging => _ringing;

  Future<void> _init() async {
    if (_ready) return;
    await _player.setAudioContext(AudioContext(
      android: const AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.alarm,
        audioFocus: AndroidAudioFocus.gainTransient,
      ),
    ));
    await _player.setReleaseMode(ReleaseMode.loop);
    await _player.setVolume(1.0);
    _ready = true;
  }

  Future<void> start() async {
    if (_ringing) return;
    _ringing = true;
    try {
      await _init();
      await _player.play(AssetSource('sounds/alarm.wav'), volume: 1.0);
      HapticFeedback.heavyImpact();
    } catch (e) {
      debugPrint('No se pudo reproducir la alarma: $e');
      _ringing = false;
    }
  }

  Future<void> stop() async {
    if (!_ringing) return;
    _ringing = false;
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('No se pudo detener la alarma: $e');
    }
  }

  Future<void> dispose() => _player.dispose();
}
