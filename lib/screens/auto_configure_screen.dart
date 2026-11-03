import 'dart:async';

import 'package:flutter/material.dart';

import '../models/camera_config.dart';
import '../services/camera_manager.dart';
import '../services/camera_session.dart';
import '../theme.dart';
import '../widgets/camera_tile.dart';

/// Un intento concreto de conexión (puerto + ruta + usuario + clave).
class _Attempt {
  _Attempt(this.config, this.credLabel);
  final CameraConfig config;
  final String credLabel;

  String get label =>
      '${config.port}${config.path}  ·  $credLabel';
}

/// Prueba automáticamente rutas RTSP y credenciales contra una IP hasta
/// conseguir video. Reproduce cada combinación de verdad (VLC) en una
/// miniatura y se detiene en la primera que conecta. Devuelve el
/// [CameraConfig] que funcionó, o null si el usuario cancela / no hay éxito.
class AutoConfigureScreen extends StatefulWidget {
  const AutoConfigureScreen({
    super.key,
    required this.host,
    required this.name,
    this.knownUser = 'admin',
    this.knownPassword = '',
    this.tryCommonCredentials = true,
    this.useTcp = true,
    this.networkCachingMs = 200,
  });

  final String host;
  final String name;
  final String knownUser;
  final String knownPassword;

  /// Si además de la clave conocida hay que probar las credenciales comunes.
  final bool tryCommonCredentials;
  final bool useTcp;
  final int networkCachingMs;

  @override
  State<AutoConfigureScreen> createState() => _AutoConfigureScreenState();
}

class _AutoConfigureScreenState extends State<AutoConfigureScreen> {
  /// Tiempo máximo que esperamos a que una combinación dé video.
  static const Duration _perAttempt = Duration(seconds: 7);

  /// Mínimo antes de descartar por error (VLC a veces reporta error y se
  /// recupera al abrir el stream).
  static const Duration _minBeforeError = Duration(milliseconds: 2000);

  final CameraManager _previewManager = CameraManager();
  final List<_Attempt> _attempts = [];
  final List<String> _tried = [];

  CameraSession? _session;
  int _index = 0;
  bool _running = true;
  CameraConfig? _result;
  Timer? _poll;
  DateTime _attemptStart = DateTime.now();

  @override
  void initState() {
    super.initState();
    _buildAttempts();
    _startAttempt();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _session?.dispose();
    _previewManager.dispose();
    super.dispose();
  }

  void _buildAttempts() {
    // Credenciales: primero la que el usuario cargó, después las comunes.
    final creds = <(String, String)>[];
    void addCred(String u, String p) {
      if (!creds.any((c) => c.$1 == u && c.$2 == p)) creds.add((u, p));
    }

    addCred(widget.knownUser.trim().isEmpty ? 'admin' : widget.knownUser.trim(),
        widget.knownPassword);
    if (widget.tryCommonCredentials) {
      for (final (u, p) in kCommonCredentials) {
        addCred(u, p);
      }
    }

    // Recorremos credencial por credencial, probando todas las rutas con cada
    // una (si la clave es correcta, alguna ruta dará video; si es incorrecta,
    // ninguna lo hará y pasamos a la siguiente clave).
    for (final (u, p) in creds) {
      final credLabel = p.isEmpty ? '$u / (sin clave)' : '$u / $p';
      for (final cand in kRtspPathCandidates) {
        _attempts.add(_Attempt(
          CameraConfig(
            id: 'probe',
            name: widget.name,
            host: widget.host,
            port: cand.port,
            path: cand.path,
            username: u,
            password: p,
            useTcp: widget.useTcp,
            networkCachingMs: widget.networkCachingMs,
          ),
          credLabel,
        ));
      }
    }
  }

  void _startAttempt() {
    _poll?.cancel();
    final old = _session;
    _session = null;
    if (old != null) {
      // Desmontamos el reproductor anterior antes de abrir el siguiente.
      Future.delayed(const Duration(milliseconds: 400), old.dispose);
    }
    if (_index >= _attempts.length) {
      setState(() => _running = false);
      return;
    }
    final attempt = _attempts[_index];
    // Pequeña pausa para que se suelte la vista nativa anterior.
    Future.delayed(const Duration(milliseconds: 250), () {
      if (!mounted || !_running) return;
      setState(() {
        _session = CameraSession(attempt.config, startMuted: true);
        _attemptStart = DateTime.now();
      });
      _poll = Timer.periodic(const Duration(milliseconds: 400), (_) => _tick());
    });
  }

  void _tick() {
    final s = _session;
    if (s == null || !mounted || !_running) return;
    final elapsed = DateTime.now().difference(_attemptStart);

    if (s.status == CameraStatus.connected) {
      _onSuccess();
      return;
    }

    final hasError = s.controller.value.hasError;
    final failedEarly = hasError && elapsed >= _minBeforeError;
    if (failedEarly || elapsed >= _perAttempt) {
      _tried.add(_attempts[_index].label);
      _index++;
      _startAttempt();
    }
  }

  void _onSuccess() {
    _poll?.cancel();
    final attempt = _attempts[_index];
    setState(() {
      _running = false;
      _result = attempt.config.copyWith();
    });
  }

  void _stop() {
    _poll?.cancel();
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final total = _attempts.length;
    final attempt = (_index < total) ? _attempts[_index] : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Autoconfigurar'),
        actions: [
          if (_running)
            IconButton(
              tooltip: 'Detener',
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: _stop,
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Miniatura en vivo del intento actual.
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  color: Colors.black,
                  child: _session == null
                      ? const Center(
                          child: Icon(Icons.hourglass_empty,
                              color: AppColors.textSecondary),
                        )
                      : CameraTile(
                          manager: _previewManager,
                          session: _session!,
                          compact: true,
                          showControls: false,
                        ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_result != null)
              _successCard(_result!)
            else if (_running)
              _runningBody(attempt, total)
            else
              _failedBody(),
            const SizedBox(height: 12),
            if (_tried.isNotEmpty) Expanded(child: _triedList()),
          ],
        ),
      ),
    );
  }

  Widget _runningBody(_Attempt? attempt, int total) {
    final done = _index.clamp(0, total);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Probando ${done + 1} de $total…',
                style: const TextStyle(color: AppColors.textPrimary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: total == 0 ? null : done / total),
        const SizedBox(height: 8),
        if (attempt != null)
          Text(
            'rtsp://${widget.host}:${attempt.label}',
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 13),
          ),
        const SizedBox(height: 8),
        const Text(
          'Dejá esta pantalla abierta. Puede tardar un par de minutos según '
          'cuántas combinaciones haya que probar.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
      ],
    );
  }

  Widget _successCard(CameraConfig config) {
    return Card(
      color: AppColors.connected.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.check_circle, color: AppColors.connected),
                SizedBox(width: 8),
                Text('¡Conecté el video!',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 10),
            Text('Puerto: ${config.port}',
                style: const TextStyle(color: AppColors.textSecondary)),
            Text('Ruta: ${config.path}',
                style: const TextStyle(color: AppColors.textSecondary)),
            Text('Usuario: ${config.username.isEmpty ? '(ninguno)' : config.username}',
                style: const TextStyle(color: AppColors.textSecondary)),
            Text('Contraseña: ${config.password.isEmpty ? '(sin clave)' : config.password}',
                style: const TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(config),
              icon: const Icon(Icons.check),
              label: const Text('Usar esta configuración'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _failedBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Row(
          children: [
            Icon(Icons.error_outline, color: AppColors.danger),
            SizedBox(width: 8),
            Expanded(
              child: Text('No pude conectar con ninguna combinación',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Probablemente la contraseña no sea de las comunes, o la cámara no '
          'tenga RTSP activado. Revisá la clave en la app oficial, activá '
          'ONVIF/RTSP, o reseteá la cámara. También podés cargar la URL a mano.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () {
            setState(() {
              _index = 0;
              _tried.clear();
              _running = true;
            });
            _startAttempt();
          },
          icon: const Icon(Icons.refresh),
          label: const Text('Probar de nuevo'),
        ),
      ],
    );
  }

  Widget _triedList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Ya probadas:',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 4),
        Expanded(
          child: ListView.builder(
            itemCount: _tried.length,
            itemBuilder: (context, i) {
              // Mostramos las últimas primero.
              final label = _tried[_tried.length - 1 - i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    const Icon(Icons.close, size: 14, color: AppColors.danger),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(label,
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 12),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
