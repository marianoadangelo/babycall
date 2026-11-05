import 'dart:convert';

/// Rutas RTSP conocidas para cámaras Srihome (y clones con el mismo firmware).
/// La más habitual en modelos recientes (SH025, SH028, SH030, NVS00x...) es
/// `:8554/profile0` (calidad alta) y `:8554/profile1` (calidad baja).
class RtspPreset {
  final String label;
  final int port;
  final String path;
  const RtspPreset(this.label, this.port, this.path);
}

const List<RtspPreset> kSrihomePresets = [
  RtspPreset('Srihome HD (8554/profile0)', 8554, '/profile0'),
  RtspPreset('Srihome SD (8554/profile1)', 8554, '/profile1'),
  RtspPreset('ONVIF stream 1 (554)', 554, '/onvif-stream1'),
  RtspPreset('H264 principal (554/1/h264major)', 554, '/1/h264major'),
  RtspPreset('cam1/mpeg4 (554)', 554, '/cam1/mpeg4'),
  RtspPreset('Srihome antiguo (10554/tcp/av0_0)', 10554, '/tcp/av0_0'),
  RtspPreset('ONVIF 1 (554/onvif1)', 554, '/onvif1'),
];

/// Puertos donde las Srihome y clones suelen exponer RTSP.
const List<int> kRtspPorts = [554, 8554, 10554];

/// Un par puerto + ruta RTSP para probar automáticamente.
class RtspCandidate {
  final int port;
  final String path;
  const RtspCandidate(this.port, this.path);
}

/// Rutas RTSP a probar en el autoconfigurador. Cubren Srihome y los clones
/// más comunes (Gadnic, ICSee, V380, YCC365, y los estilos Dahua/Hikvision/
/// Reolink que usan algunos modelos rebrandeados).
/// Primero se sondean todas con un DESCRIBE RTSP (rápido) y solo las que la
/// cámara acepta se abren de verdad con VLC.
const List<RtspCandidate> kRtspPathCandidates = [
  // Srihome y familia :8554 (SH020, SH025, SH032, SH035, SH039, SH041...)
  RtspCandidate(8554, '/profile0'),
  RtspCandidate(8554, '/profile1'),
  RtspCandidate(554, '/profile0'),
  // Srihome con firmware ONVIF :554 (SH036, SH038, SH039B...)
  RtspCandidate(554, '/onvif-stream1'),
  RtspCandidate(554, '/onvif1'),
  RtspCandidate(8554, '/onvif1'),
  // Srihome antiguas (SH024-SH029, SH035)
  RtspCandidate(554, '/cam1/mpeg4'),
  RtspCandidate(554, '/cam1/mpeg4?user={user}&pwd={pass}'),
  RtspCandidate(554, '/1/h264major'),
  RtspCandidate(10554, '/tcp/av0_0'),
  RtspCandidate(10554, '/udp/av0_0'),
  // ICSee / V380 / clones chinos (Gadnic suele caer acá)
  RtspCandidate(554, '/live/ch00_0'),
  RtspCandidate(554, '/11'),
  RtspCandidate(554, '/stream1'),
  RtspCandidate(554, '/stream11'),
  // Estilo Dahua / Hikvision / Reolink (modelos rebrandeados)
  RtspCandidate(554, '/cam/realmonitor?channel=1&subtype=0'),
  RtspCandidate(554, '/Streaming/Channels/101'),
  RtspCandidate(554, '/h264Preview_01_main'),
];

/// Reemplaza `{user}` y `{pass}` en rutas que llevan la clave en la URL.
String resolveRtspPath(String path, String user, String pass) => path
    .replaceAll('{user}', Uri.encodeQueryComponent(user))
    .replaceAll('{pass}', Uri.encodeQueryComponent(pass));

/// Credenciales de fábrica más comunes en cámaras tipo baby-call (Srihome,
/// Gadnic y clones). No hay una contraseña universal: la define el usuario al
/// emparejar, así que son solo un intento rápido antes de resetear la cámara.
const List<(String, String)> kCommonCredentials = [
  ('admin', ''),
  ('admin', '888888'),
  ('admin', 'admin'),
  ('admin', '123456'),
  ('admin', '12345'),
  ('', ''),
];

class CameraConfig {
  final String id;
  final String name;

  /// Si [customUrl] no está vacío se usa tal cual y se ignoran host/puerto/ruta.
  final String customUrl;
  final String host;
  final int port;
  final String path;
  final String username;
  final String password;

  /// RTSP sobre TCP: más estable en Wi-Fi, evita imagen gris/rota por pérdida de UDP.
  final bool useTcp;

  /// Caché de red en milisegundos (latencia vs. estabilidad). Recomendado 150-300.
  final int networkCachingMs;

  /// Si la alarma de desconexión está activa para esta cámara.
  final bool alarmEnabled;

  const CameraConfig({
    required this.id,
    required this.name,
    this.customUrl = '',
    this.host = '',
    this.port = 8554,
    this.path = '/profile0',
    this.username = 'admin',
    this.password = '',
    this.useTcp = true,
    this.networkCachingMs = 200,
    this.alarmEnabled = true,
  });

  /// URL final que se le pasa a VLC.
  String get streamUrl {
    if (customUrl.trim().isNotEmpty) return customUrl.trim();
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final auth = username.isEmpty
        ? ''
        : '${Uri.encodeComponent(username)}'
            '${password.isEmpty ? '' : ':${Uri.encodeComponent(password)}'}@';
    return 'rtsp://$auth${host.trim()}:$port$normalizedPath';
  }

  /// URL sin la contraseña, para mostrar en pantalla.
  String get displayUrl {
    if (customUrl.trim().isNotEmpty) {
      return customUrl.trim().replaceAllMapped(
          RegExp(r'(://[^:/@]+):[^@]*@'), (m) => '${m[1]}:****@');
    }
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return 'rtsp://${host.trim()}:$port$normalizedPath';
  }

  CameraConfig copyWith({
    String? name,
    String? customUrl,
    String? host,
    int? port,
    String? path,
    String? username,
    String? password,
    bool? useTcp,
    int? networkCachingMs,
    bool? alarmEnabled,
  }) {
    return CameraConfig(
      id: id,
      name: name ?? this.name,
      customUrl: customUrl ?? this.customUrl,
      host: host ?? this.host,
      port: port ?? this.port,
      path: path ?? this.path,
      username: username ?? this.username,
      password: password ?? this.password,
      useTcp: useTcp ?? this.useTcp,
      networkCachingMs: networkCachingMs ?? this.networkCachingMs,
      alarmEnabled: alarmEnabled ?? this.alarmEnabled,
    );
  }

  /// Todo lo que obliga a recrear el reproductor si cambia.
  bool sameStreamAs(CameraConfig other) =>
      streamUrl == other.streamUrl &&
      useTcp == other.useTcp &&
      networkCachingMs == other.networkCachingMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'customUrl': customUrl,
        'host': host,
        'port': port,
        'path': path,
        'username': username,
        'password': password,
        'useTcp': useTcp,
        'networkCachingMs': networkCachingMs,
        'alarmEnabled': alarmEnabled,
      };

  factory CameraConfig.fromJson(Map<String, dynamic> json) => CameraConfig(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Cámara',
        customUrl: json['customUrl'] as String? ?? '',
        host: json['host'] as String? ?? '',
        port: json['port'] as int? ?? 8554,
        path: json['path'] as String? ?? '/profile0',
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
        useTcp: json['useTcp'] as bool? ?? true,
        networkCachingMs: json['networkCachingMs'] as int? ?? 200,
        alarmEnabled: json['alarmEnabled'] as bool? ?? true,
      );

  static String encodeList(List<CameraConfig> cams) =>
      jsonEncode(cams.map((c) => c.toJson()).toList());

  static List<CameraConfig> decodeList(String raw) =>
      (jsonDecode(raw) as List)
          .map((e) => CameraConfig.fromJson(e as Map<String, dynamic>))
          .toList();
}
