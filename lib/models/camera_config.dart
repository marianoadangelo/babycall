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
