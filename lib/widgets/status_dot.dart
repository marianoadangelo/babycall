import 'package:flutter/material.dart';

import '../services/camera_session.dart';
import '../theme.dart';

/// Punto verde (conectado), ámbar (conectando/pausado) o rojo (desconectado).
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.status, this.size = 12});

  final CameraStatus status;
  final double size;

  static Color colorFor(CameraStatus status) => switch (status) {
        CameraStatus.connected => AppColors.connected,
        CameraStatus.connecting => AppColors.connecting,
        CameraStatus.paused => AppColors.textSecondary,
        CameraStatus.disconnected => AppColors.danger,
      };

  static String labelFor(CameraStatus status) => switch (status) {
        CameraStatus.connected => 'Conectado',
        CameraStatus.connecting => 'Conectando…',
        CameraStatus.paused => 'En pausa',
        CameraStatus.disconnected => 'Desconectado',
      };

  @override
  Widget build(BuildContext context) {
    final color = colorFor(status);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: size * 0.6)],
      ),
    );
  }
}
