import 'package:flutter/material.dart';

import '../models/camera_config.dart';
import '../services/camera_manager.dart';
import '../services/camera_session.dart';
import '../services/network_scanner.dart';
import '../theme.dart';
import '../widgets/camera_tile.dart';
import 'discovery_screen.dart';

/// Credenciales de fábrica más comunes en cámaras Srihome y clones. No hay una
/// contraseña universal: en estos modelos la define el usuario al emparejar, así
/// que son solo un intento rápido antes de resetear la cámara.
const List<(String, String)> kCommonCredentials = [
  ('admin', ''),
  ('admin', 'admin'),
  ('admin', '123456'),
  ('admin', '12345'),
];

sealed class CameraFormResult {}

class CameraFormSaved extends CameraFormResult {
  CameraFormSaved(this.config);
  final CameraConfig config;
}

class CameraFormDeleted extends CameraFormResult {
  CameraFormDeleted(this.id);
  final String id;
}

/// Pantalla para agregar o editar una cámara.
class CameraFormScreen extends StatefulWidget {
  const CameraFormScreen({super.key, this.existing});

  final CameraConfig? existing;

  @override
  State<CameraFormScreen> createState() => _CameraFormScreenState();
}

class _CameraFormScreenState extends State<CameraFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _path;
  late final TextEditingController _user;
  late final TextEditingController _pass;
  late final TextEditingController _url;
  late bool _manualUrl;
  late bool _useTcp;
  late double _caching;
  bool _showPass = false;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final c = widget.existing;
    _name = TextEditingController(text: c?.name ?? 'Cuarto del bebé');
    _host = TextEditingController(text: c?.host ?? '192.168.');
    _port = TextEditingController(text: '${c?.port ?? 8554}');
    _path = TextEditingController(text: c?.path ?? '/profile0');
    _user = TextEditingController(text: c?.username ?? 'admin');
    _pass = TextEditingController(text: c?.password ?? '');
    _url = TextEditingController(text: c?.customUrl ?? '');
    _manualUrl = (c?.customUrl ?? '').isNotEmpty;
    _useTcp = c?.useTcp ?? true;
    _caching = (c?.networkCachingMs ?? 200).toDouble();
  }

  @override
  void dispose() {
    for (final t in [_name, _host, _port, _path, _user, _pass, _url]) {
      t.dispose();
    }
    super.dispose();
  }

  CameraConfig _draft() {
    return CameraConfig(
      id: widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: _name.text.trim().isEmpty ? 'Cámara' : _name.text.trim(),
      customUrl: _manualUrl ? _url.text.trim() : '',
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 8554,
      path: _path.text.trim(),
      username: _user.text.trim(),
      password: _pass.text,
      useTcp: _useTcp,
      networkCachingMs: _caching.round(),
      alarmEnabled: widget.existing?.alarmEnabled ?? true,
    );
  }

  void _applyPreset(RtspPreset p) {
    setState(() {
      _port.text = '${p.port}';
      _path.text = p.path;
    });
  }

  /// Abre el buscador de red y, si el usuario elige una cámara, precarga su
  /// IP y puerto en el asistente.
  Future<void> _discover() async {
    final device = await Navigator.of(context).push<DiscoveredDevice>(
      MaterialPageRoute(builder: (_) => const DiscoveryScreen()),
    );
    if (device == null || !mounted) return;
    setState(() {
      _manualUrl = false;
      _host.text = device.host;
      _port.text = '${device.bestRtspPort}';
      // En el puerto 554 la ruta típica de Srihome por ONVIF es otra.
      if (device.bestRtspPort == 554 && _path.text == '/profile0') {
        _path.text = '/onvif-stream1';
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Cargué la IP ${device.host}. Escribí usuario y '
          'contraseña y tocá "Probar".'),
      duration: const Duration(seconds: 4),
    ));
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(CameraFormSaved(_draft()));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar cámara'),
        content: Text('¿Eliminar "${widget.existing!.name}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      Navigator.of(context).pop(CameraFormDeleted(widget.existing!.id));
    }
  }

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _TestDialog(config: _draft()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Editar cámara' : 'Agregar cámara'),
        actions: [
          if (_editing)
            IconButton(
              tooltip: 'Eliminar',
              icon: const Icon(Icons.delete_outline, color: AppColors.danger),
              onPressed: _delete,
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Nombre', prefixIcon: Icon(Icons.label_outline)),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _discover,
                icon: const Icon(Icons.wifi_find),
                label: const Text('Buscar cámaras en la red'),
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Asistente Srihome'), icon: Icon(Icons.auto_fix_high)),
                ButtonSegment(value: true, label: Text('URL completa'), icon: Icon(Icons.link)),
              ],
              selected: {_manualUrl},
              onSelectionChanged: (s) => setState(() => _manualUrl = s.first),
            ),
            const SizedBox(height: 16),
            if (_manualUrl) ..._manualFields() else ..._assistantFields(),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('RTSP por TCP'),
              subtitle: const Text('Más estable en Wi-Fi. Desactivalo solo si la imagen no carga.'),
              value: _useTcp,
              onChanged: (v) => setState(() => _useTcp = v),
            ),
            const SizedBox(height: 8),
            Text('Caché de red: ${_caching.round()} ms',
                style: const TextStyle(color: AppColors.textPrimary)),
            Slider(
              min: 100,
              max: 1000,
              divisions: 18,
              value: _caching,
              label: '${_caching.round()} ms',
              onChanged: (v) => setState(() => _caching = v),
            ),
            const Text(
              'Menos caché = menos retraso. Si la imagen se corta o se ve gris, subila a 300-500 ms.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _test,
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('Probar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.check),
                    label: const Text('Guardar'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const _HelpCard(),
          ],
        ),
      ),
    );
  }

  List<Widget> _assistantFields() {
    return [
      TextFormField(
        controller: _host,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          labelText: 'IP de la cámara',
          hintText: '192.168.1.50',
          prefixIcon: Icon(Icons.router_outlined),
        ),
        validator: (v) {
          final t = (v ?? '').trim();
          if (t.isEmpty || t == '192.168.') return 'Ingresá la IP local de la cámara';
          if (t.contains('/') || t.contains(' ')) return 'Solo la IP, sin rtsp:// ni rutas';
          return null;
        },
      ),
      const SizedBox(height: 12),
      const Text('Ruta conocida', style: TextStyle(color: AppColors.textSecondary)),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final p in kSrihomePresets)
            ChoiceChip(
              label: Text(p.label),
              selected: _port.text == '${p.port}' && _path.text == p.path,
              onSelected: (_) => _applyPreset(p),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          SizedBox(
            width: 110,
            child: TextFormField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Puerto'),
              onChanged: (_) => setState(() {}),
              validator: (v) {
                final n = int.tryParse((v ?? '').trim());
                return (n == null || n <= 0 || n > 65535) ? 'Inválido' : null;
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              controller: _path,
              decoration: const InputDecoration(labelText: 'Ruta'),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _user,
        autocorrect: false,
        decoration: const InputDecoration(labelText: 'Usuario', prefixIcon: Icon(Icons.person_outline)),
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _pass,
        obscureText: !_showPass,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: 'Contraseña de la cámara',
          prefixIcon: const Icon(Icons.lock_outline),
          suffixIcon: IconButton(
            icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showPass = !_showPass),
          ),
        ),
      ),
      const SizedBox(height: 10),
      const Text('¿No recordás la clave? Probá combinaciones comunes y tocá "Probar":',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final (user, pass) in kCommonCredentials)
            ActionChip(
              avatar: const Icon(Icons.vpn_key_outlined, size: 16),
              label: Text(pass.isEmpty ? '$user / (sin clave)' : '$user / $pass'),
              onPressed: () => setState(() {
                _user.text = user;
                _pass.text = pass;
                _showPass = true;
              }),
            ),
        ],
      ),
    ];
  }

  List<Widget> _manualFields() {
    return [
      TextFormField(
        controller: _url,
        keyboardType: TextInputType.url,
        autocorrect: false,
        maxLines: 2,
        minLines: 1,
        decoration: const InputDecoration(
          labelText: 'URL del stream',
          hintText: 'rtsp://admin:clave@192.168.1.50:8554/profile0',
          prefixIcon: Icon(Icons.link),
        ),
        validator: (v) {
          final t = (v ?? '').trim();
          if (t.isEmpty) return 'Ingresá la URL';
          if (!RegExp(r'^(rtsp|rtsps|http|https|rtmp)://', caseSensitive: false).hasMatch(t)) {
            return 'Debe empezar con rtsp://, http:// o rtmp://';
          }
          return null;
        },
      ),
    ];
  }
}

/// Reproduce la configuración en borrador para comprobar que funciona.
class _TestDialog extends StatefulWidget {
  const _TestDialog({required this.config});
  final CameraConfig config;

  @override
  State<_TestDialog> createState() => _TestDialogState();
}

class _TestDialogState extends State<_TestDialog> {
  late final CameraManager _manager = CameraManager();
  late final CameraSession _session = CameraSession(widget.config, startMuted: true);

  @override
  void dispose() {
    _session.dispose();
    _manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      contentPadding: const EdgeInsets.all(12),
      title: const Text('Prueba de conexión'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: CameraTile(
                manager: _manager,
                session: _session,
                compact: true,
                showControls: false,
              ),
            ),
            const SizedBox(height: 8),
            ListenableBuilder(
              listenable: _session,
              builder: (context, _) {
                final s = _session.status;
                final msg = switch (s) {
                  CameraStatus.connected => '✅ ¡Funciona! Ya podés guardar.',
                  CameraStatus.connecting => 'Conectando con ${widget.config.displayUrl}…',
                  CameraStatus.paused => 'En pausa',
                  CameraStatus.disconnected =>
                    '❌ No llega video. Revisá IP, puerto, ruta y contraseña, o probá otra ruta conocida.'
                        '${_session.lastError != null ? '\n(${_session.lastError})' : ''}',
                };
                return Text(msg, style: const TextStyle(color: AppColors.textPrimary));
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar')),
      ],
    );
  }
}

class _HelpCard extends StatelessWidget {
  const _HelpCard();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: AppColors.textSecondary, height: 1.4);
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('¿Cómo encuentro los datos de mi cámara Srihome?',
                style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            SizedBox(height: 8),
            Text(
              '1. IP: tocá "Buscar cámaras en la red" y la app rastrea la red Wi-Fi '
              'y te carga la IP sola. También la ves en la app de Srihome '
              '(Configuración → Información del dispositivo) o en el router. '
              'Conviene reservarla (IP fija/DHCP estático) en el router.\n'
              '2. Usuario: casi siempre "admin".\n'
              '3. Contraseña: esta NO se puede detectar por la red; es la que vos '
              'pusiste al emparejar la cámara en la app de Srihome. En algunos modelos '
              'está en Configuración → Contraseña del dispositivo, o hay que activar '
              '"ONVIF/RTSP" en la configuración avanzada.\n'
              '4. Ruta: la más común es puerto 8554 y /profile0 (HD) o /profile1 (más liviana). '
              'Si no anda, probá las otras rutas conocidas con el botón "Probar".\n'
              '5. Tip: podés verificar la URL en una PC con VLC → Medio → Abrir ubicación de red.',
              style: style,
            ),
            SizedBox(height: 12),
            Text('Si no recordás la contraseña',
                style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            SizedBox(height: 8),
            Text(
              '• No existe forma de "descubrirla" por la red: el video RTSP está '
              'protegido justamente para que nadie más la vea.\n'
              '• Primero probá los accesos comunes de arriba (admin con clave vacía o '
              'admin/admin) y tocá "Probar".\n'
              '• Si ninguno entra, abrí la app oficial de Srihome: ahí podés ver o '
              'cambiar la contraseña del dispositivo sin resetear nada.\n'
              '• Último recurso: resetear la cámara. Mantené apretado el botón RESET '
              '(5-10 s, suele estar al lado del slot SD o en la base) hasta que reinicie. '
              'Vuelve de fábrica y la emparejás de nuevo en la app poniendo una clave nueva.',
              style: style,
            ),
          ],
        ),
      ),
    );
  }
}
