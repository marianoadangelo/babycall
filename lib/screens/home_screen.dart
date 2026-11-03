import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/camera_config.dart';
import '../services/camera_manager.dart';
import '../services/camera_session.dart';
import '../theme.dart';
import '../widgets/camera_tile.dart';
import '../widgets/status_dot.dart';
import 'camera_form_screen.dart';

enum ViewMode { single, grid }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.manager});

  final CameraManager manager;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  CameraManager get manager => widget.manager;

  ViewMode _mode = ViewMode.single;
  String? _selectedId;
  bool _fullscreen = false;

  CameraSession? get _selected {
    final sessions = manager.sessions;
    if (sessions.isEmpty) return null;
    return manager.byId(_selectedId ?? '') ?? sessions.first;
  }

  Future<void> _setFullscreen(bool value) async {
    setState(() => _fullscreen = value);
    if (value) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  Future<void> _openForm({CameraConfig? existing}) async {
    if (_fullscreen) await _setFullscreen(false);
    if (!mounted) return;
    final result = await Navigator.of(context).push<CameraFormResult>(
      MaterialPageRoute(builder: (_) => CameraFormScreen(existing: existing)),
    );
    if (result == null) return;
    switch (result) {
      case CameraFormSaved(:final config):
        if (existing == null) {
          await manager.addCamera(config);
          setState(() {
            _selectedId = config.id;
            _mode = ViewMode.single;
          });
        } else {
          await manager.updateCamera(config);
        }
      case CameraFormDeleted(:final id):
        await manager.removeCamera(id);
        if (_selectedId == id) setState(() => _selectedId = null);
    }
  }

  void _select(String id) {
    setState(() {
      _selectedId = id;
      _mode = ViewMode.single;
    });
  }

  void _step(int delta) {
    final sessions = manager.sessions;
    if (sessions.length < 2) return;
    final current = sessions.indexOf(_selected!);
    final next = (current + delta) % sessions.length;
    setState(() => _selectedId = sessions[next < 0 ? next + sessions.length : next].config.id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        return PopScope(
          canPop: !_fullscreen,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _fullscreen) _setFullscreen(false);
          },
          child: Scaffold(
            appBar: _fullscreen ? null : _buildAppBar(),
            body: SafeArea(
              top: !_fullscreen,
              bottom: !_fullscreen,
              left: !_fullscreen,
              right: !_fullscreen,
              child: Column(
                children: [
                  if (manager.anyLost) _AlarmBanner(manager: manager),
                  Expanded(
                    child: manager.sessions.isEmpty
                        ? _EmptyState(onAdd: () => _openForm())
                        : _buildStage(),
                  ),
                  if (!_fullscreen && _mode == ViewMode.single && manager.sessions.length > 1)
                    _CameraSwitcher(
                      manager: manager,
                      selectedId: _selected?.config.id,
                      onSelect: _select,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final master = manager.alarmMasterEnabled;
    return AppBar(
      title: const Text('Baby Call'),
      actions: [
        IconButton(
          tooltip: master ? 'Desactivar todas las alarmas' : 'Activar alarmas',
          icon: Icon(
            master ? Icons.notifications_active : Icons.notifications_off,
            color: master ? AppColors.connected : AppColors.textSecondary,
          ),
          onPressed: () async {
            await manager.setAlarmMaster(!master);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(master
                  ? 'Alarma de desconexión DESACTIVADA'
                  : 'Alarma de desconexión activada'),
              duration: const Duration(seconds: 2),
            ));
          },
        ),
        if (manager.sessions.length > 1)
          IconButton(
            tooltip: _mode == ViewMode.grid ? 'Ver una cámara' : 'Ver en cuadrícula',
            icon: Icon(_mode == ViewMode.grid ? Icons.crop_square : Icons.grid_view),
            onPressed: () => setState(() =>
                _mode = _mode == ViewMode.grid ? ViewMode.single : ViewMode.grid),
          ),
        IconButton(
          tooltip: 'Agregar cámara',
          icon: const Icon(Icons.add_a_photo_outlined),
          onPressed: () => _openForm(),
        ),
        PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'test') manager.testAlarm();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'test', child: Text('Probar sonido de alarma')),
          ],
        ),
      ],
    );
  }

  /// Todas las cámaras se mantienen montadas siempre (para que sigan
  /// recibiendo video y vigilándose). En vista individual la seleccionada se
  /// dibuja encima del resto; en cuadrícula se reparten en celdas.
  Widget _buildStage() {
    final sessions = manager.sessions;
    final selected = _selected!;
    final grid = _mode == ViewMode.grid && sessions.length > 1;

    return LayoutBuilder(builder: (context, box) {
      final rects = grid
          ? _gridRects(sessions.length, box.biggest)
          : List.filled(sessions.length, Offset.zero & box.biggest);

      // Orden de pintado: en vista individual, la seleccionada al final (arriba).
      final order = [...sessions];
      if (!grid) {
        order
          ..remove(selected)
          ..add(selected);
      }

      return GestureDetector(
        onHorizontalDragEnd: grid
            ? null
            : (d) {
                final v = d.primaryVelocity ?? 0;
                if (v.abs() > 300) _step(v < 0 ? 1 : -1);
              },
        child: Stack(
          children: [
            for (final s in order)
              Positioned.fromRect(
                key: ValueKey(s.config.id),
                rect: rects[sessions.indexOf(s)],
                child: _wrapHidden(
                  hidden: !grid && s != selected,
                  child: Padding(
                    padding: EdgeInsets.all(grid ? 2 : 0),
                    child: CameraTile(
                      manager: manager,
                      session: s,
                      compact: grid,
                      isFullscreen: _fullscreen,
                      onTap: grid ? () => _select(s.config.id) : null,
                      onDoubleTap: grid ? null : () => _setFullscreen(!_fullscreen),
                      onFullscreen: () {
                        if (grid) _select(s.config.id);
                        _setFullscreen(!_fullscreen);
                      },
                      onEdit: () => _openForm(existing: s.config),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }

  Widget _wrapHidden({required bool hidden, required Widget child}) {
    if (!hidden) return child;
    return IgnorePointer(child: ExcludeSemantics(child: child));
  }

  /// Elige la cantidad de columnas que deja las celdas 16:9 más grandes.
  List<Rect> _gridRects(int n, Size size) {
    var bestCols = 1;
    var bestArea = 0.0;
    for (var cols = 1; cols <= n; cols++) {
      final rows = (n / cols).ceil();
      final w = size.width / cols;
      final h = size.height / rows;
      final videoW = math.min(w, h * 16 / 9);
      final area = videoW * videoW * 9 / 16;
      if (area > bestArea) {
        bestArea = area;
        bestCols = cols;
      }
    }
    final rows = (n / bestCols).ceil();
    final w = size.width / bestCols;
    final h = size.height / rows;
    return [
      for (var i = 0; i < n; i++)
        Rect.fromLTWH((i % bestCols) * w, (i ~/ bestCols) * h, w, h),
    ];
  }
}

class _AlarmBanner extends StatelessWidget {
  const _AlarmBanner({required this.manager});
  final CameraManager manager;

  @override
  Widget build(BuildContext context) {
    final names = manager.sessions
        .where((s) => manager.isLost(s.config.id))
        .map((s) => s.config.name)
        .join(', ');
    return Material(
      color: AppColors.danger,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 30),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '¡Cámara Desconectada!',
                    style: TextStyle(
                        color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900),
                  ),
                  Text(names,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white)),
                ],
              ),
            ),
            if (manager.alarmRinging)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.danger,
                ),
                onPressed: manager.snooze,
                icon: const Icon(Icons.volume_off),
                label: const Text('Silenciar'),
              )
            else if (manager.snoozed)
              const Text('Silenciada', style: TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}

class _CameraSwitcher extends StatelessWidget {
  const _CameraSwitcher({
    required this.manager,
    required this.selectedId,
    required this.onSelect,
  });

  final CameraManager manager;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          for (final s in manager.sessions)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ListenableBuilder(
                listenable: s,
                builder: (context, _) => ChoiceChip(
                  selected: s.config.id == selectedId,
                  onSelected: (_) => onSelect(s.config.id),
                  avatar: StatusDot(status: s.status, size: 10),
                  label: Text(s.config.name),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.child_friendly_outlined, size: 72, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            const Text('Todavía no agregaste ninguna cámara',
                style: TextStyle(fontSize: 18, color: AppColors.textPrimary)),
            const SizedBox(height: 8),
            const Text(
              'Agregá tu cámara Srihome con su IP local para empezar a monitorear.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Agregar cámara'),
            ),
          ],
        ),
      ),
    );
  }
}
