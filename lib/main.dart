import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'screens/home_screen.dart';
import 'services/camera_manager.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Un error no atrapado se registra en vez de dejar la app trabada.
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Error no atrapado: $error\n$stack');
    return true;
  };
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: AppColors.background,
    statusBarIconBrightness: Brightness.light,
  ));
  // La interfaz se dibuja de inmediato y la inicialización (preferencias,
  // reproductores, alarma) corre después: así nada puede dejar la app
  // trabada en el logo de inicio.
  runApp(const BabyCallApp());
}

class BabyCallApp extends StatelessWidget {
  const BabyCallApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Baby Call',
      debugShowCheckedModeBanner: false,
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.dark,
      home: const _Bootstrap(),
    );
  }
}

/// Inicializa el [CameraManager] mostrando un indicador, y si falla muestra
/// el error con un botón para reintentar.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  CameraManager? _manager;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (_error != null) setState(() => _error = null);
    // Un monitor de bebé no debe apagar la pantalla solo. Si falla, se sigue.
    unawaited(WakelockPlus.enable().catchError((Object e) {
      debugPrint('No se pudo mantener la pantalla encendida: $e');
    }));
    try {
      final manager = CameraManager();
      await manager.load().timeout(const Duration(seconds: 10));
      if (!mounted) return;
      setState(() => _manager = manager);
    } catch (e, st) {
      debugPrint('Fallo al iniciar: $e\n$st');
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = _manager;
    if (manager != null) return HomeScreen(manager: manager);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: _error == null
              ? const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Iniciando Baby Call…',
                        style: TextStyle(color: AppColors.textSecondary)),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: AppColors.danger, size: 56),
                    const SizedBox(height: 12),
                    const Text('No se pudo iniciar la app',
                        style: TextStyle(fontSize: 18, color: AppColors.textPrimary)),
                    const SizedBox(height: 8),
                    SelectableText('$_error',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textSecondary)),
                    const SizedBox(height: 20),
                    FilledButton(onPressed: _start, child: const Text('Reintentar')),
                  ],
                ),
        ),
      ),
    );
  }
}
