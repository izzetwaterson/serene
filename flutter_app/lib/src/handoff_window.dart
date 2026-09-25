import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app_theme.dart';
import 'data.dart';
import 'folder_picker.dart';
import 'format.dart';
import 'handoff.dart';
import 'rust/api/handoff.dart' as ffi;
import 'strings.dart';
import 'theme.dart';
import 'widgets.dart';

/// Ayri bir isletim sistemi penceresinde acilan "İndirme Bilgileri" paneli.
/// Tarayicidan devralinan indirme onay beklerken gosterilir.
///
/// Pencere kendi motorunu kurmaz: karari `ipc.json` uzerinden calisan ornegin
/// motoruna iletir. Boylece iki surec ayni gorev listesine yazmaz.
///
/// Yerlesim yataydir: solda indirme bilgileri, sagda karar dugmeleri. Pencere
/// ekranin ortasinda kisa ve genis durur, boylece uzun adresler tek satir
/// kaydirmadan okunur.
class HandoffWindow extends StatefulWidget {
  const HandoffWindow({super.key, required this.task, this.preview = false});

  final Task task;

  /// Ornizleme gorevleri motorun listesinde yoktur; karar denemez.
  final bool preview;

  @override
  State<HandoffWindow> createState() => _HandoffWindowState();
}

class _HandoffWindowState extends State<HandoffWindow>
    with WidgetsBindingObserver {
  late final TextEditingController _name = TextEditingController(
    text: widget.task.filename,
  );

  /// Secilebilir kayit klasoru: gorevdeki yol bir oneri, kullanici degistirebilir.
  late String _dir = widget.task.dir;

  String? _notice;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _name.dispose();
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

  String get _note {
    if (widget.task.total == 0) {
      return T.serverSizeUnknown;
    }
    if (widget.task.resumable) {
      return T.serverSegmented;
    }
    return T.serverSingle;
  }

  /// Yerel klasor diyaloğu: secilen yol hem gostergeye hem karara girer.
  Future<void> _browse() async {
    final picked = await pickFolder(
      title: T.chooseFolderTitle,
      initialDirectory: _dir.trim().isEmpty ? null : _dir.trim(),
    );
    if (picked == null || !mounted) return;
    setState(() => _dir = picked);
  }

  /// Karar: yer/ad motora yazilir, `start` ile hemen indirmeye alinir.
  Future<void> _decide({required bool start}) async {
    final name = _name.text.trim();
    if (_busy) return;
    if (name.isEmpty) {
      setState(() => _notice = T.nameEmpty);
      return;
    }
    if (_dir.trim().isEmpty) {
      setState(() => _notice = T.dirEmpty);
      return;
    }
    if (widget.preview) {
      setState(() => _notice = T.sampleTaskNoEngine);
      return;
    }

    setState(() {
      _busy = true;
      _notice = null;
    });
    // Köprü çağrısı bloklayıcıdır: meşgul durumu önce çizilsin.
    await WidgetsBinding.instance.endOfFrame;
    try {
      ffi.confirmHandoff(
        id: widget.task.id,
        destDir: _dir,
        filename: name,
        start: start,
      );
    } catch (error) {
      if (mounted) setState(() => _busy = false);
      _show(engineReason(error));
      return;
    }
    _close();
  }

  /// Karar yok: devralma listeden cikarilir.
  Future<void> _cancel() async {
    if (_busy) return;
    if (widget.preview) {
      setState(() => _notice = T.sampleTaskNoEngine);
      return;
    }

    setState(() => _busy = true);
    await WidgetsBinding.instance.endOfFrame;
    try {
      ffi.cancelHandoff(id: widget.task.id);
    } catch (error) {
      if (mounted) setState(() => _busy = false);
      _show(engineReason(error));
      return;
    }
    _close();
  }

  void _show(String message) {
    if (mounted) setState(() => _notice = message);
  }

  /// Surec cikar: pencere yok olur, ana pencere sıradaki onayı açar.
  Never _close() {
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final style = styleOf(task);
    final sizeLine = task.total > 0
        ? T.sizeWithBytes(fmtBytes(task.total), _grouped(task.total))
        : T.unknownSize;

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
                      T.handoffTitle,
                      style: head(20, color: Serene.onBackground),
                    ),
                  ),
                  CircleButton(
                    icon: 'close',
                    title: T.closeAndDownloadLater,
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
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(28, 0, 24, 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Serene.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(
                              Serene.radiusTile,
                            ),
                            border: Border.all(color: Serene.borderSoft),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: style.box,
                                  borderRadius: BorderRadius.circular(
                                    Serene.radiusTile,
                                  ),
                                ),
                                child: Center(
                                  child: SIcon(
                                    style.icon,
                                    size: 24,
                                    color: style.tone,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      task.filename,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: body(15, weight: FontWeight.w600),
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Serene.surfaceContainer,
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            categoryTitles[task.category] ??
                                                T.other,
                                            style: body(
                                              10,
                                              weight: FontWeight.w600,
                                              color: Serene.secondary,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Flexible(
                                          child: Text(
                                            sizeLine,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: mono(
                                              11,
                                              color: Serene.secondary,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        Field(
                          label: T.addressLabel,
                          child: ReadOnlyField(text: task.url),
                        ),
                        const SizedBox(height: 20),
                        Field(
                          label: T.folderLabel,
                          child: Row(
                            children: [
                              Expanded(child: ReadOnlyField(text: _dir)),
                              const SizedBox(width: 8),
                              HoverSurface(
                                onTap: _busy ? null : _browse,
                                radius: Serene.radiusField,
                                background: Serene.surfaceContainer,
                                hoverBackground: Serene.surfaceContainerHigh,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                child: Text(
                                  T.browse,
                                  style: body(13, weight: FontWeight.w500),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        Field(
                          label: T.fileNameLabel,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Serene.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(
                                Serene.radiusField,
                              ),
                              border: Border.all(
                                color: Serene.borderInput,
                              ),
                            ),
                            child: TextField(
                              controller: _name,
                              cursorColor: Serene.primary,
                              style: body(13),
                              onSubmitted: (_) => _decide(start: true),
                              decoration: const InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Serene.surfaceContainerLow.withValues(
                              alpha: 0.7,
                            ),
                            borderRadius: BorderRadius.circular(
                              Serene.radiusField,
                            ),
                            border: Border.all(color: Serene.borderFaint),
                          ),
                          child: Text(
                            _note,
                            style: body(11, color: Serene.secondary, height: 1.6),
                          ),
                        ),
                        if (_notice != null) ...[
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Serene.errorContainer.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              _notice!,
                              style: body(12, color: Serene.onErrorContainer),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Container(
                  width: 1,
                  color: Serene.outlineVariant.withValues(alpha: 0.5),
                ),
                SizedBox(
                  width: 236,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 28, 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Spacer(),
                        HoverSurface(
                          onTap: () => _decide(start: true),
                          radius: 999,
                          background: Serene.primary,
                          hoverBackground: Serene.primaryHover,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: Text(
                              T.startDownload,
                              style: body(
                                13,
                                weight: FontWeight.w500,
                                color: Serene.onPrimary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        HoverSurface(
                          onTap: () => _decide(start: false),
                          radius: 999,
                          background: Serene.surfaceContainer,
                          hoverBackground: Serene.surfaceContainerHigh,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: Text(
                              T.downloadLater,
                              style: body(13, weight: FontWeight.w500),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        HoverSurface(
                          onTap: _cancel,
                          radius: 999,
                          background: Colors.transparent,
                          hoverBackground: Serene.surfaceContainer,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: Text(
                              T.cancel,
                              style: body(13, color: Serene.secondary),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Binlik ayraci dile gore: 1.450.000 ya da 1,450,000.
String _grouped(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buffer.write(T.thousandSeparator);
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
