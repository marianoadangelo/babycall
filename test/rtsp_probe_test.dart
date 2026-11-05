import 'package:baby_call/models/camera_config.dart';
import 'package:baby_call/services/rtsp_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Digest MD5 con qop=auth (ejemplo RFC 2617)', () {
    final r = RtspProbe.digestResponse(
      username: 'Mufasa',
      password: 'Circle Of Life',
      realm: 'testrealm@host.com',
      nonce: 'dcd98b7102dd2f0e8b11d0f600bfb0c093',
      method: 'GET',
      uri: '/dir/index.html',
      qop: 'auth',
      nc: '00000001',
      cnonce: '0a4f113b',
    );
    expect(r, '6629fae49393a05397450978507c4ef1');
  });

  test('parsea respuesta 401 con desafío Digest', () {
    final res = RtspProbe.parseResponse('RTSP/1.0 401 Unauthorized\r\n'
        'CSeq: 1\r\n'
        'WWW-Authenticate: Digest realm="IP Camera", nonce="abc123"\r\n'
        'WWW-Authenticate: Basic realm="IP Camera"\r\n'
        '\r\n')!;
    expect(res.code, 401);
    expect(res.authenticate.length, 2);

    final auth = RtspProbe.buildAuthorization(
      challenges: res.authenticate,
      method: 'DESCRIBE',
      uri: 'rtsp://10.0.0.5:554/onvif1',
      username: 'admin',
      password: 'secreto',
    )!;
    expect(auth, startsWith('Digest username="admin", realm="IP Camera"'));
    expect(auth, contains('nonce="abc123"'));
    expect(auth, isNot(contains('qop=')));
  });

  test('cae a Basic si no hay Digest', () {
    final auth = RtspProbe.buildAuthorization(
      challenges: ['Basic realm="x"'],
      method: 'DESCRIBE',
      uri: 'rtsp://h/p',
      username: 'admin',
      password: 'admin',
    );
    expect(auth, 'Basic YWRtaW46YWRtaW4=');
  });

  test('respuesta que no es RTSP devuelve null', () {
    expect(RtspProbe.parseResponse('HTTP/1.1 200 OK\r\n\r\n'), isNull);
  });

  test('rutas con usuario y clave en la URL', () {
    expect(resolveRtspPath('/cam1/mpeg4?user={user}&pwd={pass}', 'admin', 'a&b'),
        '/cam1/mpeg4?user=admin&pwd=a%26b');
    expect(kRtspPathCandidates.any((c) => c.port == 10554), isTrue);
  });
}
