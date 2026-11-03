import 'dart:async';

import 'package:flutter/material.dart';

import '../services/network_scanner.dart';
import '../theme.dart';

/// Busca cámaras en la red local y deja elegir una. Devuelve el
/// [DiscoveredDevice] seleccionado (o null si el usuario cancela).
class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  final NetworkScanner _scanner = NetworkScanner();
  StreamSubscription<ScanProgress>? _sub;

  ScanProgress? _progress;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _scanner.cancel();
    _sub?.cancel();
    super.dispose();
  }

  void _start() {
    _scanner.cancel();
    _sub?.cancel();
    setState(() {
      _scanning = true;
      _progress = null;
    });
    _sub = _scanner.scan().listen(
      (p) {
        if (mounted) setState(() => _progress = p);
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
      onError: (_) {
        if (mounted) setState(() => _scanning = false);
      },
    );
  }

  void _stop() {
    _scanner.cancel();
    setState(() => _scanning = false);
  }

  @override
  Widget build(BuildContext context) {
    final devices = _progress?.devices ?? const [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Buscar cámaras'),
        actions: [
          if (_scanning)
            IconButton(
              tooltip: 'Detener',
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: _stop,
            )
          else
            IconButton(
              tooltip: 'Buscar de nuevo',
              icon: const Icon(Icons.refresh),
              onPressed: _start,
            ),
        ],
      ),
      body: Column(
        children: [
          if (_scanning)
            LinearProgressIndicator(value: _progress?.fraction)
          else
            const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                if (_scanning)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (_scanning) const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _progress?.phase ?? 'Preparando búsqueda…',
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: devices.isEmpty
                ? _emptyOrSearching()
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    itemCount: devices.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final d = devices[i];
                      return Card(
                        margin: EdgeInsets.zero,
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: d.onvif
                                ? AppColors.connected.withValues(alpha: 0.2)
                                : AppColors.textSecondary.withValues(alpha: 0.15),
                            child: Icon(
                              d.onvif ? Icons.videocam : Icons.lan_outlined,
                              color: d.onvif
                                  ? AppColors.connected
                                  : AppColors.textSecondary,
                            ),
                          ),
                          title: Text(d.title,
                              style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w600)),
                          subtitle: Text(d.subtitle,
                              style: const TextStyle(
                                  color: AppColors.textSecondary)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).pop(d),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              'Elegí tu cámara para cargar su IP y puerto. Después vas a tener '
              'que escribir el usuario y la contraseña (no se pueden detectar '
              'por la red).',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppColors.textSecondary.withValues(alpha: 0.9),
                  fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyOrSearching() {
    if (_scanning) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Buscando dispositivos en tu red…\nPuede tardar hasta un minuto.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_find_outlined,
                size: 64, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            const Text(
              'No se encontraron cámaras',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 18),
            ),
            const SizedBox(height: 8),
            const Text(
              'Verificá que la cámara esté encendida y conectada a la misma '
              'red Wi-Fi que el teléfono. También podés cargarla a mano con su IP.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.refresh),
              label: const Text('Buscar de nuevo'),
            ),
          ],
        ),
      ),
    );
  }
}
