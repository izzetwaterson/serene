import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'data.dart';
import 'format.dart';
import 'theme.dart';
import 'widgets.dart';

/// Ayri bir isletim sistemi penceresinde acilan "İndirme Bilgileri" paneli.
/// Tarayicidan devralinan indirme onay beklerken gosterilir.
class HandoffWindow extends StatefulWidget {
  const HandoffWindow({super.key, required this.task});

  final Task task;

  @override
  State<HandoffWindow> createState() => _HandoffWindowState();
}

class _HandoffWindowState extends State<HandoffWindow> {
  late final TextEditingController _name = TextEditingController(text: widget.task.filename);
  String? _notice;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _note {
    if (widget.task.total == 0) {
      return 'Sunucu boyutu bildirmedi; boyut indirme başlarken netleşecek.';
    }
    if (widget.task.resumable) {
      return 'Sunucu parçalı indirmeyi destekliyor; dosya birden çok bağlantıyla '
          'daha hızlı inebilir.';
    }
    return 'Sunucu parçalı indirmeyi desteklemiyor; dosya tek bağlantıyla inecek.';
  }

  void _decide() {
    setState(() {
      _notice = 'Spike: karar indirme motoruna iletilemedi — motor bu sürümde bağlı değil.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final style = styleOf(task);
    final sizeLine = task.total > 0
        ? '${fmtBytes(task.total)} (${_grouped(task.total)} bayt)'
        : 'Boyut bilinmiyor';

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
                    child: Text('İndirme Bilgileri',
                        style: head(20, color: Serene.onBackground)),
                  ),
                  CircleButton(
                    icon: 'close',
                    title: 'Kapat (sonra indir)',
                    size: 32,
                    iconSize: 17,
                    background: Serene.surfaceContainer,
                    hoverBackground: Serene.surfaceContainerHigh,
                    foreground: Serene.secondary,
                    onTap: windowManager.close,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Serene.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(Serene.radiusTile),
                      border: Border.all(color: const Color(0x80DCD8CE)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: style.box,
                            borderRadius: BorderRadius.circular(Serene.radiusTile),
                          ),
                          child: Center(
                              child: SIcon(style.icon, size: 24, color: style.tone)),
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
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Serene.surfaceContainer,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      categoryTitles[task.category] ?? 'Diğer',
                                      style: body(10,
                                          weight: FontWeight.w600,
                                          color: Serene.secondary),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      sizeLine,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: mono(11, color: Serene.secondary),
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
                  _Field(
                    label: 'Adres',
                    child: _ReadOnlyField(text: task.url),
                  ),
                  const SizedBox(height: 20),
                  _Field(
                    label: 'Kayıt klasörü',
                    child: Row(
                      children: [
                        Expanded(child: _ReadOnlyField(text: task.dir)),
                        const SizedBox(width: 8),
                        HoverSurface(
                          onTap: () => setState(() =>
                              _notice = 'Spike: klasör seçimi henüz bağlı değil.'),
                          radius: Serene.radiusField,
                          background: Serene.surfaceContainer,
                          hoverBackground: Serene.surfaceContainerHigh,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          child: Text('Gözat',
                              style: body(13, weight: FontWeight.w500)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _Field(
                    label: 'Dosya adı',
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                      decoration: BoxDecoration(
                        color: Serene.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(Serene.radiusField),
                        border: Border.all(color: const Color(0x99DCD8CE)),
                      ),
                      child: TextField(
                        controller: _name,
                        cursorColor: Serene.primary,
                        style: body(13),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Serene.surfaceContainerLow.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(Serene.radiusField),
                      border: Border.all(color: const Color(0x66DCD8CE)),
                    ),
                    child: Text(_note,
                        style: body(11, color: Serene.secondary, height: 1.6)),
                  ),
                  if (_notice != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Serene.errorContainer.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(_notice!,
                          style: body(12, color: Serene.onErrorContainer)),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      HoverSurface(
                        onTap: _decide,
                        background: Colors.transparent,
                        hoverBackground: Serene.surfaceContainer,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Text('İptal',
                            style: body(13, color: Serene.secondary)),
                      ),
                      const Spacer(),
                      HoverSurface(
                        onTap: _decide,
                        radius: 999,
                        background: Serene.surfaceContainer,
                        hoverBackground: Serene.surfaceContainerHigh,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 10),
                        child: Text('Sonra İndir',
                            style: body(13, weight: FontWeight.w500)),
                      ),
                      const SizedBox(width: 8),
                      HoverSurface(
                        onTap: _decide,
                        radius: 999,
                        background: Serene.primary,
                        hoverBackground: const Color(0xE63D6A4B),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 10),
                        child: Row(
                          children: [
                            Text('İndirmeyi Başlat',
                                style: body(13,
                                    weight: FontWeight.w500,
                                    color: Serene.onPrimary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// tr-TR binlik ayraci: 1.450.000
String _grouped(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write('.');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
            label.toUpperCase(),
            style: body(12,
                weight: FontWeight.w600, color: Serene.outline, letterSpacing: 0.6),
          ),
        ),
        child,
      ],
    );
  }
}

class _ReadOnlyField extends StatelessWidget {
  const _ReadOnlyField({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: Serene.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Serene.radiusField),
        border: Border.all(color: const Color(0x99DCD8CE)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: mono(12, color: Serene.onSurface),
      ),
    );
  }
}
