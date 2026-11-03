import 'package:flutter/material.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';

import '../services/camera_manager.dart';
import '../services/camera_session.dart';
import '../theme.dart';
import 'status_dot.dart';

/// Un reproductor de cámara con su indicador de estado, controles y aviso de
/// desconexión. Se usa tanto en la cuadrícula como en la vista individual.
class CameraTile extends StatelessWidget {
  const CameraTile({
    super.key,
    required this.manager,
    required this.session,
    required this.compact,
    this.onTap,
    this.onDoubleTap,
    this.onFullscreen,
    this.onEdit,
    this.isFullscreen = false,
    this.showControls = true,
  });

  final CameraManager manager;
  final CameraSession session;

  /// Versión reducida de los controles (para la cuadrícula).
  final bool compact;
  final bool isFullscreen;
  final bool showControls;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onFullscreen;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, manager]),
      builder: (context, _) {
        final cfg = session.config;
        final lost = manager.isLost(cfg.id);
        final status = session.status;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onDoubleTap: onDoubleTap,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black,
              border: lost
                  ? Border.all(color: AppColors.danger, width: 3)
                  : Border.all(color: Colors.transparent, width: 0),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _Video(session: session),
                if (status != CameraStatus.connected)
                  _StateOverlay(session: session, lost: lost, compact: compact),
                // Cabecera: nombre + estado.
                if (showControls)
                  Positioned(
                    left: 8,
                    top: 8,
                    right: 8,
                    child: _Header(session: session, compact: compact, onEdit: onEdit),
                  ),
                if (showControls)
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: _Controls(
                      manager: manager,
                      session: session,
                      compact: compact,
                      isFullscreen: isFullscreen,
                      onFullscreen: onFullscreen,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Video extends StatelessWidget {
  const _Video({required this.session});
  final CameraSession session;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final ratio = (box.maxWidth > 0 && box.maxHeight > 0)
          ? box.maxWidth / box.maxHeight
          : 16 / 9;
      return Center(
        child: VlcPlayer(
          // Si se recrea el controlador (cambio de URL/caché) se recrea la vista.
          key: ObjectKey(session.controller),
          controller: session.controller,
          aspectRatio: ratio,
          placeholder: const Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    });
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.session, required this.compact, this.onEdit});
  final CameraSession session;
  final bool compact;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final status = session.status;
    return Row(
      children: [
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StatusDot(status: status, size: compact ? 10 : 12),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    compact
                        ? session.config.name
                        : '${session.config.name} · ${StatusDot.labelFor(status)}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: compact ? 12 : 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!compact && onEdit != null) ...[
          const Spacer(),
          _RoundButton(icon: Icons.settings, tooltip: 'Editar cámara', onPressed: onEdit!),
        ],
      ],
    );
  }
}

class _StateOverlay extends StatelessWidget {
  const _StateOverlay({required this.session, required this.lost, required this.compact});
  final CameraSession session;
  final bool lost;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final status = session.status;
    if (status == CameraStatus.paused) {
      return Container(
        color: Colors.black54,
        alignment: Alignment.center,
        child: Icon(Icons.pause_circle_outline,
            size: compact ? 40 : 72, color: AppColors.textSecondary),
      );
    }
    if (!lost) {
      final secs = session.timeWithoutVideo.inMilliseconds / 1000;
      return Container(
        color: Colors.black38,
        alignment: Alignment.center,
        child: Text(
          secs < 0.5 ? 'Conectando…' : 'Sin señal… ${secs.toStringAsFixed(0)} s',
          style: const TextStyle(color: AppColors.connecting, fontWeight: FontWeight.w600),
        ),
      );
    }
    return Container(
      color: AppColors.dangerDark.withValues(alpha: 0.85),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam_off, color: Colors.white, size: compact ? 32 : 64),
          const SizedBox(height: 8),
          Text(
            '¡Cámara Desconectada!',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: compact ? 16 : 28,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (!compact) ...[
            const SizedBox(height: 6),
            Text(
              'Sin video hace ${session.timeWithoutVideo.inSeconds} s · reintentando…',
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.manager,
    required this.session,
    required this.compact,
    required this.isFullscreen,
    this.onFullscreen,
  });

  final CameraManager manager;
  final CameraSession session;
  final bool compact;
  final bool isFullscreen;
  final VoidCallback? onFullscreen;

  @override
  Widget build(BuildContext context) {
    final cfg = session.config;
    final alarmOn = cfg.alarmEnabled && manager.alarmMasterEnabled;
    final buttons = <Widget>[
      _RoundButton(
        icon: session.userPaused ? Icons.play_arrow : Icons.pause,
        tooltip: session.userPaused ? 'Reproducir' : 'Pausar',
        small: compact,
        onPressed: session.togglePlayPause,
      ),
      _RoundButton(
        icon: session.muted ? Icons.volume_off : Icons.volume_up,
        tooltip: session.muted ? 'Activar audio' : 'Silenciar audio',
        small: compact,
        active: !session.muted,
        onPressed: session.toggleMute,
      ),
      _RoundButton(
        icon: cfg.alarmEnabled ? Icons.notifications_active : Icons.notifications_off,
        tooltip: cfg.alarmEnabled ? 'Desactivar alarma' : 'Activar alarma',
        small: compact,
        active: alarmOn,
        activeColor: AppColors.connected,
        onPressed: () => manager.setCameraAlarm(cfg.id, !cfg.alarmEnabled),
      ),
      if (onFullscreen != null)
        _RoundButton(
          icon: isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          tooltip: isFullscreen ? 'Salir de pantalla completa' : 'Pantalla completa',
          small: compact,
          onPressed: onFullscreen!,
        ),
    ];
    return Row(
      mainAxisAlignment: compact ? MainAxisAlignment.end : MainAxisAlignment.center,
      children: [
        for (final b in buttons) Padding(padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 6), child: b),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.small = false,
    this.active = false,
    this.activeColor = AppColors.accent,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool small;
  final bool active;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    final size = small ? 34.0 : 52.0;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.55),
        shape: CircleBorder(
          side: BorderSide(color: active ? activeColor : Colors.white24, width: 1.5),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon,
                size: small ? 18 : 26, color: active ? activeColor : AppColors.textPrimary),
          ),
        ),
      ),
    );
  }
}
