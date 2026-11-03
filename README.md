# Baby Call 👶📹

Monitor de bebé para Android que muestra en vivo cámaras IP **Srihome** (RTSP) de la red local, con baja latencia y una **alarma sonora** si se pierde el video por más de 5 segundos.

## Funciones

- Video en vivo con **libVLC** (`flutter_vlc_player`) y caché de red baja (200 ms por defecto, ajustable de 100 a 1000 ms por cámara), RTSP sobre TCP, descarte de cuadros atrasados.
- **Varias cámaras**: agregar, editar, eliminar; cambiar entre ellas con chips o deslizando; **vista en cuadrícula** (toque una cámara para agrandarla).
- **Pantalla completa horizontal** (botón o doble toque).
- **Indicador de estado**: punto verde (conectado), ámbar (conectando), rojo (desconectado), gris (en pausa).
- **Alarma de desconexión**: si no llega video durante 5 s suena una sirena fuerte y continua por el canal de **alarma** de Android (`audioplayers`) y aparece el aviso rojo **"¡Cámara Desconectada!"**. Se apaga sola cuando vuelve el video. La app reintenta conectar cada 6 s.
- Botones por cámara: **Play/Pausa**, **audio on/off**, **alarma on/off**, pantalla completa. Interruptor global de alarmas en la barra superior y botón **Silenciar** en el aviso.
- Pausar una cámara a propósito **no** dispara la alarma.
- Modo oscuro, pantalla siempre encendida (`wakelock_plus`), configuración guardada en el teléfono (`shared_preferences`).
- Formulario con **"Probar"** para verificar la URL antes de guardarla.

## ¿Cuál es la URL RTSP de mi Srihome?

La más común en modelos actuales (SH025, SH028, SH030, etc.):

```
rtsp://admin:CONTRASEÑA@IP_DE_LA_CAMARA:8554/profile0   (HD)
rtsp://admin:CONTRASEÑA@IP_DE_LA_CAMARA:8554/profile1   (calidad baja, menos retraso)
```

Otras rutas que usan algunos modelos (vienen como opciones rápidas en la app): `:554/onvif-stream1`, `:554/1/h264major`, `:554/cam1/mpeg4`.

1. **IP**: en la app Srihome → la cámara → Configuración → Información del dispositivo / Red, o en la lista de dispositivos del router. Conviene reservarla como IP fija en el router.
2. **Usuario**: `admin`.
3. **Contraseña**: la contraseña del dispositivo configurada en la app Srihome (algunos modelos piden crearla o activar ONVIF/RTSP en la configuración avanzada).
4. **Verificar en la PC**: VLC → Medio → Abrir ubicación de red → pegar la URL. Si ahí se ve, en la app también.

Fuentes: [hamradio.my – SriHome SH025 con RTSP](https://hamradio.my/viewing-srihome-sh025-ip-camera-on-linux-with-mpv/), [iSpy – URLs Srihome](https://www.ispyconnect.com/camera/srihome).

## Compilar e instalar

Requisitos: Flutter 3.47+ y Android SDK (Android Studio).

```bash
flutter pub get
flutter run                 # con el teléfono conectado por USB y depuración activada
flutter build apk --release # genera build/app/outputs/flutter-apk/app-release.apk
```

El teléfono tiene que estar en la **misma red Wi-Fi** que la cámara.

## Estructura

```
lib/
  main.dart                       arranque, tema oscuro, wakelock
  theme.dart                      colores
  models/camera_config.dart       configuración de cámara, URL RTSP, presets Srihome
  services/camera_session.dart    reproductor VLC por cámara + detección de señal + reconexión
  services/camera_manager.dart    lista de cámaras, persistencia, lógica de alarma (5 s)
  services/alarm_service.dart     sirena en bucle por el canal de alarma
  screens/home_screen.dart        vista individual / cuadrícula / pantalla completa
  screens/camera_form_screen.dart agregar/editar/probar cámara + ayuda
  widgets/camera_tile.dart        reproductor con controles y aviso rojo
  widgets/status_dot.dart         punto de estado
assets/sounds/alarm.wav           sirena de dos tonos
```

## Cómo se detecta la pérdida de video

Cada 500 ms se revisa cada cámara: hay video si VLC está en estado `playing` y la posición de reproducción sigue avanzando (si se congela más de 2,5 s se toma como pérdida). Si pasan 5 s seguidos sin video, la cámara queda "desconectada", suena la alarma (si está activada para esa cámara y el interruptor global está encendido) y la app intenta reconectar.

## Limitaciones conocidas

- Para que la vigilancia siga con la pantalla apagada o la app en segundo plano, el reproductor sigue activo, pero Android puede cerrar la app tras un rato si queda en segundo plano. Lo más confiable es dejar la app abierta con la pantalla encendida (ya lo hace sola) y el cargador conectado. Un servicio en primer plano sería la mejora siguiente.
- No se probó aún con una cámara Srihome real.

## Segundo plano y pantalla apagada

La app arranca un servicio en primer plano de Android (notificación persistente
"Baby Call · Vigilando …") mientras haya cámaras configuradas. Así el sistema no
cierra la app cuando se apaga la pantalla o se cambia de app, y la alarma sigue
sonando (y vibrando) si una cámara deja de enviar video. En Android 13+ la app
pide permiso de notificaciones al abrirse: convenía aceptarlo para ver el estado
en la barra de notificaciones (la vigilancia funciona igual si se rechaza).

## Compilar el APK en GitHub Actions

`.github/workflows/build-apk.yml` compila el APK en cada push a `main` (o a mano
desde la pestaña Actions) y lo publica como `baby-call.apk` en la release
`latest` del repositorio: `https://github.com/<usuario>/<repo>/releases/latest`.
