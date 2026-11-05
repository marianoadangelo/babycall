import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Resultado de preguntarle a la cámara por una ruta RTSP concreta.
enum RtspProbeStatus {
  /// La cámara aceptó la ruta y la clave (respondió 200 al DESCRIBE).
  ok,

  /// La cámara pide usuario/clave y la que mandamos no sirvió (401/403).
  unauthorized,

  /// La ruta no existe en la cámara (404/454...).
  notFound,

  /// No hay nada escuchando en ese puerto (conexión rechazada o timeout).
  closed,

  /// Respondió algo raro o se cortó; no sabemos (se prueba igual con VLC).
  unknown,
}

class RtspProbeResult {
  const RtspProbeResult(this.status, [this.code]);
  final RtspProbeStatus status;

  /// Código RTSP de la respuesta (200, 401, 404...), si hubo.
  final int? code;

  @override
  String toString() => '${status.name}${code == null ? '' : ' ($code)'}';
}

/// Sondeo rápido de RTSP sin abrir el video: manda un `DESCRIBE` (con
/// autenticación Digest o Basic si la cámara la pide) y mira el código de
/// respuesta. Tarda menos de un segundo por ruta, así que permite descartar
/// decenas de combinaciones puerto/ruta/clave antes de probarlas con VLC.
class RtspProbe {
  static const Duration _connectTimeout = Duration(milliseconds: 1500);
  static const Duration _responseTimeout = Duration(milliseconds: 2500);

  /// ¿Hay algo escuchando por TCP en host:port?
  static Future<bool> isPortOpen(String host, int port) async {
    try {
      final s = await Socket.connect(host, port, timeout: _connectTimeout);
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Pregunta por `rtsp://host:port{path}` con las credenciales dadas.
  static Future<RtspProbeResult> describe({
    required String host,
    required int port,
    required String path,
    String username = '',
    String password = '',
  }) async {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = 'rtsp://$host:$port$normalizedPath';

    final first = await _request(host, port, uri, cseq: 1);
    if (first == null) return const RtspProbeResult(RtspProbeStatus.closed);
    if (first.code != 401) return _classify(first.code);

    // Pide autenticación: sin usuario no hay nada más que hacer.
    if (username.isEmpty) {
      return const RtspProbeResult(RtspProbeStatus.unauthorized, 401);
    }
    final auth = buildAuthorization(
      challenges: first.authenticate,
      method: 'DESCRIBE',
      uri: uri,
      username: username,
      password: password,
    );
    if (auth == null) return const RtspProbeResult(RtspProbeStatus.unknown, 401);

    // Conexión nueva: muchas cámaras cierran el socket después del 401.
    final second =
        await _request(host, port, uri, cseq: 2, authorization: auth);
    if (second == null) return const RtspProbeResult(RtspProbeStatus.unknown);
    return _classify(second.code);
  }

  static RtspProbeResult _classify(int code) {
    if (code >= 200 && code < 300) {
      return RtspProbeResult(RtspProbeStatus.ok, code);
    }
    if (code == 401 || code == 403) {
      return RtspProbeResult(RtspProbeStatus.unauthorized, code);
    }
    if (code == 404 || code == 454 || code == 400) {
      return RtspProbeResult(RtspProbeStatus.notFound, code);
    }
    return RtspProbeResult(RtspProbeStatus.unknown, code);
  }

  /// Envía un DESCRIBE y devuelve el código y los desafíos de autenticación.
  /// null = no se pudo conectar (puerto cerrado / host caído).
  static Future<RtspResponse?> _request(
    String host,
    int port,
    String uri, {
    required int cseq,
    String? authorization,
  }) async {
    Socket socket;
    try {
      socket = await Socket.connect(host, port, timeout: _connectTimeout);
    } catch (_) {
      return null;
    }
    try {
      final req = StringBuffer()
        ..write('DESCRIBE $uri RTSP/1.0\r\n')
        ..write('CSeq: $cseq\r\n')
        ..write('Accept: application/sdp\r\n')
        ..write('User-Agent: BabyCall\r\n');
      if (authorization != null) req.write('Authorization: $authorization\r\n');
      req.write('\r\n');
      socket.write(req.toString());
      await socket.flush();

      final buffer = StringBuffer();
      final done = Completer<void>();
      final sub = socket.listen(
        (data) {
          buffer.write(latin1.decode(data, allowInvalid: true));
          if (buffer.toString().contains('\r\n\r\n') && !done.isCompleted) {
            done.complete();
          }
        },
        onError: (_) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      await done.future.timeout(_responseTimeout, onTimeout: () {});
      await sub.cancel();
      return parseResponse(buffer.toString()) ?? const RtspResponse(0, []);
    } catch (_) {
      return const RtspResponse(0, []);
    } finally {
      try {
        socket.destroy();
      } catch (_) {}
    }
  }

  /// Parsea la cabecera de una respuesta RTSP. Público para tests.
  static RtspResponse? parseResponse(String raw) {
    final lines = raw.split(RegExp(r'\r?\n'));
    if (lines.isEmpty) return null;
    final m = RegExp(r'^RTSP/\d\.\d\s+(\d{3})').firstMatch(lines.first.trim());
    if (m == null) return null;
    final code = int.parse(m.group(1)!);
    final challenges = <String>[];
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) break;
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      if (line.substring(0, idx).trim().toLowerCase() == 'www-authenticate') {
        challenges.add(line.substring(idx + 1).trim());
      }
    }
    return RtspResponse(code, challenges);
  }

  /// Arma la cabecera Authorization (prefiere Digest, si no Basic).
  static String? buildAuthorization({
    required List<String> challenges,
    required String method,
    required String uri,
    required String username,
    required String password,
    String? cnonce,
  }) {
    final digest = challenges.firstWhere(
        (c) => c.toLowerCase().startsWith('digest'),
        orElse: () => '');
    if (digest.isNotEmpty) {
      final params = parseAuthParams(digest.substring(6));
      final realm = params['realm'] ?? '';
      final nonce = params['nonce'] ?? '';
      final qopRaw = params['qop'];
      final qop = (qopRaw != null &&
              qopRaw.split(',').map((e) => e.trim()).contains('auth'))
          ? 'auth'
          : null;
      final cn = cnonce ?? _randomHex(8);
      const nc = '00000001';
      final response = digestResponse(
        username: username,
        password: password,
        realm: realm,
        nonce: nonce,
        method: method,
        uri: uri,
        qop: qop,
        nc: nc,
        cnonce: cn,
      );
      final sb = StringBuffer('Digest username="$username", realm="$realm", '
          'nonce="$nonce", uri="$uri", response="$response"');
      if (params['opaque'] != null) sb.write(', opaque="${params['opaque']}"');
      if (qop != null) sb.write(', qop=$qop, nc=$nc, cnonce="$cn"');
      return sb.toString();
    }
    if (challenges.any((c) => c.toLowerCase().startsWith('basic'))) {
      return 'Basic ${base64.encode(utf8.encode('$username:$password'))}';
    }
    return null;
  }

  /// Respuesta Digest MD5 (RFC 2617).
  static String digestResponse({
    required String username,
    required String password,
    required String realm,
    required String nonce,
    required String method,
    required String uri,
    String? qop,
    String nc = '00000001',
    String cnonce = '',
  }) {
    String md5hex(String s) => md5.convert(utf8.encode(s)).toString();
    final ha1 = md5hex('$username:$realm:$password');
    final ha2 = md5hex('$method:$uri');
    if (qop == null) return md5hex('$ha1:$nonce:$ha2');
    return md5hex('$ha1:$nonce:$nc:$cnonce:$qop:$ha2');
  }

  /// `realm="x", nonce="y", qop="auth"` → mapa.
  static Map<String, String> parseAuthParams(String s) {
    final out = <String, String>{};
    final re = RegExp(r'(\w+)\s*=\s*(?:"([^"]*)"|([^,\s]+))');
    for (final m in re.allMatches(s)) {
      out[m.group(1)!.toLowerCase()] = m.group(2) ?? m.group(3) ?? '';
    }
    return out;
  }

  static String _randomHex(int bytes) {
    final r = Random.secure();
    return List.generate(bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

/// Código de respuesta RTSP y cabeceras WWW-Authenticate.
class RtspResponse {
  const RtspResponse(this.code, this.authenticate);
  final int code;
  final List<String> authenticate;
}
