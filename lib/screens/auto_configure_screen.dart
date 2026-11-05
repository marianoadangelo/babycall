import 'dart:async';

import 'package:flutter/material.dart';

import '../models/camera_config.dart';
import '../services/camera_manager.dart';
import '../services/camera_session.dart';
import '../services/rtsp_probe.dart';
import '../theme.dart';
import '../widgets/camera_tile.dart';

/// Un intento concreto de conexión (puerto + ruta + usuario + clave).
class _Attempt {
  _Attempt(this.config, this.credLabel);
  final CameraConfig config;
  final String credLabel;

  String get label =>
      '${config.port}${config.path.replaceAll(RegExp(r'pwd=[^&]*'), 'pwd=***')}'
      '  ·  $credLabel';
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

  /// Fase rápida previa a VLC: puertos abiertos + DESCRIBE por ruta.
  bool _probing = true;
  String _probeStatus = 'Revisando puertos de la cámara…';
  int _probeDone = 0;
  int _probeTotal = 0;

  /// Explicación de por qué no conectó (se muestra si falla todo).
  String? _diagnosis;

  /// Para que un reintento invalide la corrida anterior.
  int _runId = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _runId++;
    _poll?.cancel();
    _session?.dispose();
    _previewManager.dispose();
    super.dispose();
  }

  /// Credenciales a probar: primero la que cargó el usuario, luego las comunes.
  List<(String, String)> _credentials() {
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
    return creds;
  }

  _Attempt _attemptFor(RtspCandidate cand, String u, String p) {
    final credLabel = p.isEmpty ? '$u / (sin clave)' : '$u / ${'*' * p.length}';
    return _Attempt(
      CameraConfig(
        id: 'probe',
        name: widget.name,
        host: widget.host,
        port: cand.port,
        path: resolveRtspPath(cand.path, u, p),
        username: u,
        password: p,
        useTcp: widget.useTcp,
        networkCachingMs: widget.networkCachingMs,
      ),
      credLabel,
    );
  }

  bool _alive(int id) => mounted && id == _runId;

  Future<RtspProbeResult> _describe(RtspCandidate cand, String u, String p) =>
      RtspProbe.describe(
        host: widget.host,
        port: cand.port,
        path: resolveRtspPath(cand.path, u, p),
        username: u,
        password: p,
      );

  Future<void> _run() async {
    final id = ++_runId;
    _poll?.cancel();
    final old = _session;
    _session = null;
    if (old != null) {
      Future.delayed(const Duration(milliseconds: 400), old.dispose);
    }
    _attempts.clear();
    _tried.clear();
    _index = 0;
    setState(() {
      _running = true;
      _probing = true;
      _result = null;
      _diagnosis = null;
      _probeDone = 0;
      _probeTotal = 0;
      _probeStatus = 'Revisando puertos RTSP (${kRtspPorts.join(', ')})…';
    });

    // 1) ¿Qué puertos RTSP tiene abiertos la cámara?
    final open = <int>[];
    await Future.wait(kRtspPorts.map((port) async {
      if (await RtspProbe.isPortOpen(widget.host, port)) open.add(port);
    }));
    open.sort();
    if (!_alive(id)) return;
    if (open.isEmpty) {
      setState(() {
        _running = false;
        _probing = false;
        _diagnosis = 'La cámara (${widget.host}) no tiene abierto ningún '
            'puerto RTSP (${kRtspPorts.join(', ')}).\n\n'
            '• Revisá que la IP sea la correcta: en la app Srihome suele '
            'estar en la información del dispositivo, o en la lista de '
            'equipos del router. También podés usar "Buscar cámaras en la '
            'red".\n'
            '• En la app Srihome buscá una opción ONVIF / RTSP / NVR y '
            'activala.\n'
            '• Si no existe esa opción, este modelo probablemente solo '
            'transmite por la nube de Srihome y no se puede ver fuera de su '
            'app.';
      });
      return;
    }

    // 2) Sondeo rápido con DESCRIBE: descarta rutas y claves incorrectas
    //    sin abrir el video (menos de un segundo por ruta).
    final creds = _credentials();
    final candidates =
        kRtspPathCandidates.where((c) => open.contains(c.port)).toList();
    setState(() {
      _probeTotal = candidates.length;
      _probeStatus = 'Puertos abiertos: ${open.join(', ')}. '
          'Preguntando por las rutas conocidas…';
    });

    final ok = <_Attempt>[];
    final unsure = <_Attempt>[];
    var unauthorizedPaths = 0;
    for (final cand in candidates) {
      if (!_alive(id)) return;
      final (u0, p0) = creds.first;
      var r = await _describe(cand, u0, p0);
      if (r.status == RtspProbeStatus.ok) {
        ok.add(_attemptFor(cand, u0, p0));
      } else if (r.status == RtspProbeStatus.unauthorized) {
        // La ruta puede existir pero la clave no sirve: probamos las demás.
        for (final (u, p) in creds.skip(1)) {
          if (!_alive(id)) return;
          r = await _describe(cand, u, p);
          if (r.status == RtspProbeStatus.ok) {
            ok.add(_attemptFor(cand, u, p));
            break;
          }
          if (r.status != RtspProbeStatus.unauthorized) break;
        }
        if (r.status == RtspProbeStatus.unauthorized) unauthorizedPaths++;
      } else if (r.status == RtspProbeStatus.unknown) {
        // Respuesta rara: no descartamos, se prueba con VLC al final.
        for (final (u, p) in creds) {
          unsure.add(_attemptFor(cand, u, p));
        }
      }
      if (!_alive(id)) return;
      setState(() => _probeDone++);
      if (ok.isNotEmpty) break; // Con una ruta buena alcanza.
    }
    if (!_alive(id)) return;

    // 3) Confirmación con VLC: primero lo que la cámara aceptó.
    _attempts
      ..addAll(ok)
      ..addAll(unsure);
    if (_attempts.isEmpty) {
      setState(() {
        _running = false;
        _probing = false;
        _diagnosis = unauthorizedPaths > 0
            ? 'La cámara responde RTSP (puerto ${open.join(', ')}) pero '
                'rechazó todas las contraseñas probadas.\n\n'
                '• Escribí en "Contraseña" la clave del DISPOSITIVO que '
                'configuraste en la app Srihome (no la del Wi-Fi ni la de tu '
                'cuenta) y volvé a autoconfigurar.\n'
                '• El usuario casi siempre es "admin".'
            : 'La cámara responde en el puerto ${open.join(', ')} pero no '
                'reconoce ninguna de las ${candidates.length} rutas '
                'conocidas.\n\n'
                'Si sabés la URL exacta (por ejemplo con la app "ONVIF Device '
                'Manager"), cargala a mano en "URL completa".';
      });
      return;
    }
    setState(() => _probing = false);
    _startAttempt();
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
      setState(() {
        _running = false;
        _diagnosis ??= 'La cámara aceptó la conexión RTSP, pero el video no '
            'llegó a reproducirse. Probá desactivar "RTSP sobre TCP" o subir '
            'la caché de red, y volvé a intentar.';
      });
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
    _runId++;
    _poll?.cancel();
    setState(() {
      _running = false;
      _probing = false;
      _diagnosis ??= 'Búsqueda detenida.';
    });
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
            else if (_running && _probing)
              _probingBody()
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

  Widget _probingBody() {
    final total = _probeTotal;
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
                total == 0
                    ? _probeStatus
                    : '$_probeStatus ($_probeDone de $total)',
                style: const TextStyle(color: AppColors.textPrimary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
            value: total == 0 ? null : (_probeDone / total).clamp(0.0, 1.0)),
      ],
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
        Text(
          _diagnosis ??
              'Probablemente la contraseña no sea de las comunes, o la cámara '
                  'no tenga RTSP activado. Revisá la clave en la app oficial, '
                  'activá ONVIF/RTSP, o reseteá la cámara. También podés '
                  'cargar la URL a mano.',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _run,
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
