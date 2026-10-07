import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app_theme.dart';
import 'data.dart';
import 'format.dart';
import 'handoff.dart';
import 'rust/api/download.dart' as ffi;
import 'strings.dart';
import 'theme.dart';
import 'widgets.dart';

/// Ayri bir isletim sistemi penceresinde acilan canli indirme penceresi.
///
/// Onay penceresi gibi kendi motorunu kurmaz; gorevi `ipc.json` uzerinden
/// calisan ornekten periyodik (400 ms) okur ve parcalari canli gosterir.
/// Yakalanan bir indirme onaydan gecip basladiginda ana pencere acar.
class DownloadWindow extends StatefulWidget {
  const DownloadWindow({super.key, required this.id, this.fetch});

  final String id;

  /// Gorevi okur; varsayilan olarak calisan ornegin koprusunu kullanir.
  /// Test icin degistirilebilir.
  final Future<Task?> Function(String id)? fetch;

  @override
  State<DownloadWindow> createState() => _DownloadWindowState();
}

class _DownloadWindowState extends State<DownloadWindow>
    with WidgetsBindingObserver {
  Task? _task;
  String? _notice;
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _poll = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => _refresh(),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Yalnizca "Sistem" seciliyken is gorur: elle secilen tema, isletim
  /// sisteminin bildirdigi parlakliktan bagimsizdir.
  @override
  void didChangePlatformBrightness() {
    if (appThemeMode.value == ThemeMode.system) {
      applyThemeMode(ThemeMode.system);
      if (mounted) setState(() {});
    }
  }

  Future<Task?> _load() async {
    final custom = widget.fetch;
    if (custom != null) return custom(widget.id);
    final raw = await ffi.taskSnapshot(id: widget.id);
    return raw == null ? null : Task.fromEngine(raw);
  }

  Future<void> _refresh() async {
    Task? task;
    try {
      task = await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() => _notice = engineReason(error));
      return;
    }
    if (!mounted) return;
    if (task == null) {
      // Gorev listeden cikti: tamamlandi/temizlendi ya da iptal edildi.
      _poll?.cancel();
      setState(() => _notice = T.downloadGone);
      return;
    }
    setState(() {
      _task = task;
      _notice = null;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    // Köprü çağrısı ağ bekler: meşgul durumu önce çizilsin.
    await WidgetsBinding.instance.endOfFrame;
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _notice = engineReason(error));
    }
    if (mounted) setState(() => _busy = false);
    await _refresh();
  }

  /// Surec cikar: pencere yok olur, indirme calisan ornekte devam eder.
  Never _close() {
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final task = _task;

    return Scaffold(
      backgroundColor: Serene.surfaceContainerLowest,
      body: Column(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => windowManager.startDragging(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 20, 28, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      T.downloadTitle,
                      style: head(20, color: Serene.onBackground),
                    ),
                  ),
                  CircleButton(
                    icon: 'close',
                    title: T.close,
                    size: 32,
                    iconSize: 17,
                    background: Serene.surfaceContainer,
                    hoverBackground: Serene.surfaceContainerHigh,
                    foreground: Serene.secondary,
                    onTap: _close,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: task == null
                ? Center(
                    child: Text(
                      T.loading,
                      style: body(13, color: Serene.secondary),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
                    child: _Details(task: task),
                  ),
          ),
          if (task != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 24),
              child: _Actions(
                task: task,
                busy: _busy,
                onPause: () => _run(() => ffi.taskPause(id: widget.id)),
                onResume: () => _run(() => ffi.taskResume(id: widget.id)),
                onRemove: () => _run(() async {
                  await ffi.taskRemove(id: widget.id);
                  _close();
                }),
              ),
            ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 20),
              child: Text(_notice!, style: body(12, color: Serene.error)),
            ),
        ],
      ),
    );
  }
}

/// Dosya bilgisi, toplam ilerleme ve parca barlari.
class _Details extends StatelessWidget {
  const _Details({required this.task});

  final Task task;

  @override
  Widget build(BuildContext context) {
    final parts = task.segments;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Serene.surfaceContainerLow,
            borderRadius: BorderRadius.circular(Serene.radiusTile),
            border: Border.all(color: Serene.borderSoft),
          ),
          child: CardHeader(
            style: styleOf(task),
            name: task.filename,
            meta: metaLine(task),
            chip: _statusChip(task),
          ),
        ),
        const SizedBox(height: 20),
        ProgressBar(ratio: percentOf(task) / 100, tone: barTone(task), height: 14),
        const SizedBox(height: 10),
        Row(
          children: [
            Text(
              '${percentOf(task).round()}%',
              style: mono(13, color: Serene.onBackground),
            ),
            const Spacer(),
            Text(
              _progress(task),
              style: body(12, color: Serene.secondary),
            ),
          ],
        ),
        if (parts.length > 1) ...[
          const SizedBox(height: 24),
          Text(
            T.connectionsCount(parts.length),
            style: body(12, color: Serene.secondary),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < parts.length; i++) ...[
                if (i > 0) const SizedBox(width: 3),
                Expanded(
                  child: ProgressBar(
                    ratio: segmentRatio(parts[i]),
                    tone: barTone(task),
                    height: 22,
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// Alt eylem cubugu: duruma gore duraklat/devam, iptal.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.task,
    required this.busy,
    required this.onPause,
    required this.onResume,
    required this.onRemove,
  });

  final Task task;
  final bool busy;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final finished = task.status == 'completed' || task.status == 'failed';
    final paused = task.status == 'paused';

    if (finished) {
      return Align(
        alignment: Alignment.centerRight,
        child: Text(
          task.status == 'completed' ? T.statusCompleted : T.statusError,
          style: body(13, weight: FontWeight.w500, color: Serene.secondary),
        ),
      );
    }

    return Row(
      children: [
        HoverSurface(
          onTap: busy ? null : onRemove,
          background: Colors.transparent,
          hoverBackground: Serene.surfaceContainer,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(T.actionCancel, style: body(13, color: Serene.secondary)),
        ),
        const Spacer(),
        HoverSurface(
          onTap: busy ? null : (paused ? onResume : onPause),
          radius: 999,
          background: Serene.primary,
          hoverBackground: Serene.primaryHover,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Text(
            paused ? T.actionResume : T.actionPause,
            style: body(13, weight: FontWeight.w500, color: Serene.onPrimary),
          ),
        ),
      ],
    );
  }
}

/// Durum rozeti widget'i.
Widget _statusChip(Task task) {
  final chip = statusChip(task);
  return StatusChip(
    label: chip.label,
    background: chip.bg,
    foreground: chip.fg,
  );
}

/// "1.2 MB / 3.4 MB • 2.4 MB/s" ozeti.
String _progress(Task task) {
  final done = fmtBytes(task.downloaded);
  final total = task.total > 0 ? fmtBytes(task.total) : T.unknownSize;
  final speed = task.status == 'downloading' ? ' • ${fmtSpeed(task.speed)}' : '';
  return '$done / $total$speed';
}
