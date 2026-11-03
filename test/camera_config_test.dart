import 'package:baby_call/models/camera_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('arma la URL RTSP de Srihome con credenciales codificadas', () {
    const c = CameraConfig(
      id: '1',
      name: 'Cuarto',
      host: '192.168.1.50',
      port: 8554,
      path: 'profile0',
      username: 'admin',
      password: 'p@ss:1',
    );
    expect(c.streamUrl, 'rtsp://admin:p%40ss%3A1@192.168.1.50:8554/profile0');
    expect(c.displayUrl, 'rtsp://192.168.1.50:8554/profile0');
  });

  test('la URL completa tiene prioridad y oculta la contraseña al mostrarla', () {
    const c = CameraConfig(
      id: '1',
      name: 'X',
      customUrl: ' rtsp://admin:secreto@10.0.0.2:554/onvif-stream1 ',
      host: 'ignorado',
    );
    expect(c.streamUrl, 'rtsp://admin:secreto@10.0.0.2:554/onvif-stream1');
    expect(c.displayUrl, 'rtsp://admin:****@10.0.0.2:554/onvif-stream1');
  });

  test('serializa y deserializa la lista de cámaras', () {
    const cams = [
      CameraConfig(id: 'a', name: 'A', host: '1.2.3.4', alarmEnabled: false),
      CameraConfig(id: 'b', name: 'B', customUrl: 'rtsp://x', networkCachingMs: 300),
    ];
    final back = CameraConfig.decodeList(CameraConfig.encodeList(cams));
    expect(back.map((c) => c.toJson()), cams.map((c) => c.toJson()));
  });

  test('detecta cambios que obligan a reabrir el stream', () {
    const a = CameraConfig(id: 'a', name: 'A', host: '1.2.3.4');
    expect(a.sameStreamAs(a.copyWith(name: 'Otro', alarmEnabled: false)), isTrue);
    expect(a.sameStreamAs(a.copyWith(networkCachingMs: 500)), isFalse);
    expect(a.sameStreamAs(a.copyWith(host: '1.2.3.5')), isFalse);
  });
}
