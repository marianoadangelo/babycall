import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Una cámara (o dispositivo con RTSP/ONVIF) encontrada en la red local.
class DiscoveredDevice {
  DiscoveredDevice(this.host);

  final String host;

  /// Puertos RTSP que respondieron (554, 8554...).
  final Set<int> rtspPorts = {};

  /// Respondió a WS-Discovery de ONVIF.
  bool onvif = false;

  /// URL del servicio ONVIF (device_service), si se descubrió.
  String? onvifXAddr;

  /// Nombre/modelo si ONVIF lo reportó (scopes), si no la IP.
  String? label;

  /// Puerto RTSP más probable para precargar en el formulario.
  int get bestRtspPort {
    if (rtspPorts.contains(8554)) return 8554;
    if (rtspPorts.contains(554)) return 554;
    if (rtspPorts.isNotEmpty) return rtspPorts.first;
    return 8554;
  }

  String get title => label?.isNotEmpty == true ? label! : host;

  String get subtitle {
    final parts = <String>[];
    if (rtspPorts.isNotEmpty) {
      parts.add('RTSP ${(rtspPorts.toList()..sort()).join(', ')}');
    }
    if (onvif) parts.add('ONVIF');
    if (parts.isEmpty) parts.add('Dispositivo');
    return '$host · ${parts.join(' · ')}';
  }
}

/// Progreso del escaneo, para mostrar en la UI.
class ScanProgress {
  ScanProgress({
    required this.phase,
    required this.done,
    required this.total,
    required this.devices,
  });

  /// Texto de la etapa actual ("Buscando por ONVIF…", "Escaneando 192.168.1.x…").
  final String phase;
  final int done;
  final int total;
  final List<DiscoveredDevice> devices;

  double get fraction => total == 0 ? 0 : (done / total).clamp(0.0, 1.0);
}

/// Busca cámaras IP en la misma red Wi-Fi/LAN que el teléfono.
///
/// Dos técnicas, sin dependencias externas (solo `dart:io`):
///  1. WS-Discovery de ONVIF: envía un Probe multicast a 239.255.255.250:3702
///     y recoge los ProbeMatch de las cámaras compatibles.
///  2. Escaneo de puertos RTSP: recorre la subred /24 del teléfono probando
///     una conexión TCP a los puertos RTSP típicos (554 y 8554) y confirma con
///     un `OPTIONS` RTSP que del otro lado hay un servidor de streaming.
class NetworkScanner {
  /// Puertos RTSP habituales en cámaras Srihome y clones.
  static const List<int> rtspPorts = [8554, 554];

  bool _cancelled = false;
  void cancel() => _cancelled = true;

  /// Ejecuta el escaneo completo y va emitiendo el progreso.
  Stream<ScanProgress> scan() async* {
    _cancelled = false;
    final Map<String, DiscoveredDevice> found = {};

    DiscoveredDevice deviceFor(String host) =>
        found.putIfAbsent(host, () => DiscoveredDevice(host));

    // --- Subred local a partir de la IP Wi-Fi del teléfono ---
    final local = await _localIPv4();
    if (local == null) {
      yield ScanProgress(
        phase: 'No se detectó una red Wi-Fi. Conectá el teléfono a la misma '
            'red que la cámara.',
        done: 1,
        total: 1,
        devices: const [],
      );
      return;
    }
    final prefix = local.substring(0, local.lastIndexOf('.') + 1); // 192.168.1.
    final myLast = int.tryParse(local.substring(local.lastIndexOf('.') + 1));

    // Total ~= hosts del escaneo RTSP + 1 fase de ONVIF.
    const hostsToScan = 254;
    final total = hostsToScan + 1;
    var done = 0;

    // --- Fase 1: ONVIF WS-Discovery (rápida, en paralelo con nada) ---
    yield ScanProgress(
      phase: 'Buscando cámaras por ONVIF…',
      done: done,
      total: total,
      devices: found.values.toList(),
    );
    try {
      await _onvifProbe((host, xaddr, name) {
        final d = deviceFor(host);
        d.onvif = true;
        d.onvifXAddr ??= xaddr;
        if (name != null && name.isNotEmpty) d.label = name;
      });
    } catch (e) {
      debugPrint('ONVIF probe falló: $e');
    }
    done += 1;
    if (_cancelled) return;
    yield ScanProgress(
      phase: 'Escaneando la red $prefix* …',
      done: done,
      total: total,
      devices: found.values.toList(),
    );

    // --- Fase 2: escaneo de puertos RTSP en la subred /24 ---
    const batchSize = 32;
    for (var start = 1; start <= 254; start += batchSize) {
      if (_cancelled) return;
      final futures = <Future<void>>[];
      for (var i = start; i < start + batchSize && i <= 254; i++) {
        if (i == myLast) {
          done++;
          continue;
        }
        final host = '$prefix$i';
        futures.add(() async {
          for (final port in rtspPorts) {
            if (_cancelled) return;
            if (await _isRtspOpen(host, port)) {
              deviceFor(host).rtspPorts.add(port);
            }
          }
        }());
      }
      await Future.wait(futures);
      done += futures.length;
      yield ScanProgress(
        phase: 'Escaneando la red $prefix* …',
        done: done,
        total: total,
        devices: (found.values.toList())
          ..sort((a, b) => _score(b).compareTo(_score(a))),
      );
    }

    yield ScanProgress(
      phase: found.isEmpty
          ? 'No se encontraron cámaras. Revisá que estén encendidas y en la '
              'misma red, o agregá la cámara a mano con su IP.'
          : 'Listo: ${found.length} dispositivo(s) encontrado(s).',
      done: total,
      total: total,
      devices: (found.values.toList())..sort((a, b) => _score(b).compareTo(_score(a))),
    );
  }

  /// Puntaje para ordenar: primero lo que más se parece a una cámara.
  int _score(DiscoveredDevice d) =>
      (d.onvif ? 2 : 0) + (d.rtspPorts.isNotEmpty ? 1 : 0);

  /// IPv4 de la interfaz Wi-Fi/LAN (descarta loopback y enlaces locales).
  Future<String?> _localIPv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      // Preferimos rangos privados típicos de LAN.
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              _is172Private(ip)) {
            return ip;
          }
        }
      }
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (e) {
      debugPrint('No se pudo leer la IP local: $e');
    }
    return null;
  }

  bool _is172Private(String ip) {
    if (!ip.startsWith('172.')) return false;
    final second = int.tryParse(ip.split('.')[1]) ?? 0;
    return second >= 16 && second <= 31;
  }

  /// ¿Hay un servidor RTSP escuchando en host:port? Conecta por TCP y confirma
  /// con un OPTIONS que la respuesta hable RTSP.
  Future<bool> _isRtspOpen(String host, int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port,
          timeout: const Duration(milliseconds: 600));
      // Pedimos OPTIONS; un servidor RTSP responde "RTSP/1.0 ...".
      socket.write('OPTIONS rtsp://$host:$port RTSP/1.0\r\nCSeq: 1\r\n\r\n');
      await socket.flush();
      final completer = Completer<bool>();
      final buffer = StringBuffer();
      late StreamSubscription sub;
      final timer = Timer(const Duration(milliseconds: 700), () {
        if (!completer.isCompleted) completer.complete(buffer.isNotEmpty);
      });
      sub = socket.listen(
        (data) {
          buffer.write(String.fromCharCodes(data));
          if (buffer.toString().toUpperCase().contains('RTSP/')) {
            if (!completer.isCompleted) completer.complete(true);
          }
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(false);
        },
        onDone: () {
          // El puerto estaba abierto aunque no hablara: igual lo marcamos.
          if (!completer.isCompleted) completer.complete(true);
        },
        cancelOnError: true,
      );
      final result = await completer.future;
      timer.cancel();
      await sub.cancel();
      return result;
    } catch (_) {
      // Rechazo de conexión / timeout = puerto cerrado.
      return false;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }

  /// WS-Discovery de ONVIF: Probe multicast y lectura de ProbeMatch.
  Future<void> _onvifProbe(
      void Function(String host, String? xaddr, String? name) onMatch) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.multicastHops = 2;
      final target = InternetAddress('239.255.255.250');
      final messageId = 'urn:uuid:${DateTime.now().microsecondsSinceEpoch}';
      final probe =
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" '
          'xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
          'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
          'xmlns:dn="http://www.onvif.org/ver10/network/wsdl">'
          '<e:Header>'
          '<w:MessageID>$messageId</w:MessageID>'
          '<w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>'
          '<w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>'
          '</e:Header>'
          '<e:Body>'
          '<d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe>'
          '</e:Body>'
          '</e:Envelope>';
      final bytes = probe.codeUnits;

      final completer = Completer<void>();
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket!.receive();
        if (dg == null) return;
        final body = String.fromCharCodes(dg.data);
        final host = dg.address.address;
        final xaddr = _firstMatch(body, RegExp(r'<[^>]*XAddrs>([^<]+)<', caseSensitive: false));
        var realHost = host;
        if (xaddr != null) {
          try {
            final uri = Uri.parse(xaddr.trim().split(' ').first);
            if (uri.host.isNotEmpty) realHost = uri.host;
          } catch (_) {}
        }
        final scopes = _firstMatch(body, RegExp(r'<[^>]*Scopes>([^<]+)<', caseSensitive: false));
        final name = _nameFromScopes(scopes);
        onMatch(realHost, xaddr?.trim(), name);
      });

      // Enviamos el Probe un par de veces (UDP se pierde) y escuchamos ~3 s.
      socket.send(bytes, target, 3702);
      await Future.delayed(const Duration(milliseconds: 400));
      if (_cancelled) return;
      socket.send(bytes, target, 3702);

      Timer(const Duration(milliseconds: 3000), () {
        if (!completer.isCompleted) completer.complete();
      });
      await completer.future;
    } finally {
      socket?.close();
    }
  }

  String? _firstMatch(String input, RegExp re) {
    final m = re.firstMatch(input);
    return m?.group(1);
  }

  /// Extrae un nombre legible de los scopes ONVIF (hardware/name).
  String? _nameFromScopes(String? scopes) {
    if (scopes == null) return null;
    for (final token in scopes.split(RegExp(r'\s+'))) {
      final decoded = Uri.decodeFull(token);
      final m = RegExp(r'onvif://www\.onvif\.org/(?:name|hardware)/(.+)$')
          .firstMatch(decoded);
      if (m != null) return m.group(1)!.replaceAll('_', ' ');
    }
    return null;
  }
}
