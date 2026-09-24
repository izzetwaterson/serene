import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data.dart';
import 'folder_picker.dart';
import 'handoff.dart' show engineReason;
import 'rust/api/commands.dart' as ffi;
import 'rust/api/dto.dart' as engine;
import 'theme.dart';
import 'widgets.dart';

/// Ayarlar katmani: web arayuzundeki `#settings-modal` ile ayni yerlesim.
/// Pencerenin ustune serilen karartma ve kaydirilabilir panel; `Esc` ya da
/// karartmaya tiklama ile kapanir.
class SettingsLayer extends StatelessWidget {
  const SettingsLayer({
    super.key,
    required this.settings,
    required this.onClose,
    required this.onSaved,
  });

  final Settings settings;
  final VoidCallback onClose;
  final ValueChanged<Settings> onSaved;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: onClose,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
              child: ColoredBox(
                color: Serene.onSurface.withValues(alpha: 0.25),
              ),
            ),
          ),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 512,
                maxHeight: height - 48,
              ),
              child: SettingsPanel(
                settings: settings,
                onClose: onClose,
                onSaved: onSaved,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Panelin kendisi: taslagi motorun ayarlarindan alir, kaydedince motora yazar.
class SettingsPanel extends StatefulWidget {
  const SettingsPanel({
    super.key,
    required this.settings,
    required this.onClose,
    required this.onSaved,
  });

  final Settings settings;
  final VoidCallback onClose;
  final ValueChanged<Settings> onSaved;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  late final TextEditingController _dir = TextEditingController(
    text: widget.settings.downloadDir,
  );
  late final TextEditingController _concurrent = TextEditingController(
    text: '${widget.settings.maxConcurrent}',
  );
  late final TextEditingController _connections = TextEditingController(
    text: '${widget.settings.connections}',
  );

  late bool _clipboard = widget.settings.watchClipboard;
  late bool _tray = widget.settings.closeToTray;
  late bool _confirm = widget.settings.confirmBrowserDownload;

  String? _status;
  Color _statusColor = Serene.primary;
  bool _busy = false;
  Timer? _closeTimer;

  @override
  void dispose() {
    _closeTimer?.cancel();
    _dir.dispose();
    _concurrent.dispose();
    _connections.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final picked = await pickFolder(
      title: 'Kayıt klasörünü seçin',
      initialDirectory: _dir.text.trim().isEmpty ? null : _dir.text.trim(),
    );
    if (picked == null || !mounted) return;
    setState(() => _dir.text = picked);
  }

  /// Motorun kabul edeceği payload; bos/gecersiz sayilar mevcut degerden dusurulur.
  engine.AppConfig _payload() => engine.AppConfig(
    downloadDir: _dir.text.trim(),
    maxConcurrent: parseCount(_concurrent.text, widget.settings.maxConcurrent),
    connections: parseCount(_connections.text, widget.settings.connections),
    watchClipboard: _clipboard,
    closeToTray: _tray,
    confirmBrowserDownload: _confirm,
  );

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final saved = await ffi.updateSettings(settings: _payload());
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Kaydedildi';
        _statusColor = Serene.primary;
      });
      widget.onSaved(Settings.fromEngine(saved));
      // Web arayuzu de onay yazi bir an gorunup pencereyi kapiyor.
      _closeTimer = Timer(const Duration(milliseconds: 600), widget.onClose);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = engineReason(error);
        _statusColor = Serene.onErrorContainer;
      });
    }
  }

  Future<void> _clearCompleted() async {
    if (_busy) return;
    try {
      final removed = await ffi.clearCompleted();
      if (!mounted) return;
      setState(() {
        _status = removed > 0
            ? '$removed kayıt silindi'
            : 'Silinecek kayıt yok';
        _statusColor = Serene.secondary;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = engineReason(error);
        _statusColor = Serene.onErrorContainer;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        LogicalKeySet(LogicalKeyboardKey.escape): const _CloseSettings(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _CloseSettings: CallbackAction<_CloseSettings>(
            onInvoke: (_) {
              widget.onClose();
              return null;
            },
          ),
        },
        // Katman acildigunda odak buraya gelir: aksi halde `Esc` arastirma
        // alanindan yukari turlanir ve bu panele hic ulasamaz.
        child: Focus(
          autofocus: true,
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Serene.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(Serene.radiusCard),
                boxShadow: Serene.shadowFloat,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Ayarlar',
                            style: head(20, color: Serene.onBackground),
                          ),
                        ),
                        CircleButton(
                          icon: 'close',
                          title: 'Kapat',
                          size: 32,
                          iconSize: 17,
                          background: Serene.surfaceContainer,
                          hoverBackground: Serene.surfaceContainerHigh,
                          foreground: Serene.secondary,
                          onTap: widget.onClose,
                        ),
                      ],
                    ),
                  ),
                  ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                    children: [
                      Field(
                        label: 'Kayıt klasörü',
                        child: Row(
                          children: [
                            Expanded(child: ReadOnlyField(text: _dir.text)),
                            const SizedBox(width: 8),
                            HoverSurface(
                              onTap: _browse,
                              radius: Serene.radiusField,
                              background: Serene.surfaceContainer,
                              hoverBackground: Serene.surfaceContainerHigh,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              child: Text(
                                'Gözat',
                                style: body(13, weight: FontWeight.w500),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Field(
                              label: 'Eşzamanlı indirme',
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _NumberField(controller: _concurrent),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Aynı anda kaç dosya iner',
                                    style: body(
                                      11,
                                      color: Serene.secondary,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Field(
                              label: 'Bağlantı / dosya',
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _NumberField(controller: _connections),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Parçalı indirmede bağlantı sayısı',
                                    style: body(
                                      11,
                                      color: Serene.secondary,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      _Toggle(
                        title: 'Panoyu izle',
                        hint: 'Kopyaladığınız bağlantıları yakalayıp önerir',
                        value: _clipboard,
                        onChanged: (value) =>
                            setState(() => _clipboard = value),
                      ),
                      const SizedBox(height: 16),
                      _Toggle(
                        title: 'Kapatınca tepsiye gizle',
                        hint: 'Kapat düğmesi uygulamayı bitirmez, indirmeler sürer',
                        value: _tray,
                        onChanged: (value) => setState(() => _tray = value),
                      ),
                      const SizedBox(height: 16),
                      _Toggle(
                        title: 'Tarayıcı indirmelerini önce sor',
                        hint: 'Devralınan indirme, bilgileri onaylanana kadar başlamaz',
                        value: _confirm,
                        onChanged: (value) => setState(() => _confirm = value),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          HoverSurface(
                            onTap: _clearCompleted,
                            background: Colors.transparent,
                            hoverBackground: Serene.surfaceContainer,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            child: Text(
                              'Tamamlananları temizle',
                              style: body(
                                13,
                                weight: FontWeight.w500,
                                color: Serene.secondary,
                              ),
                            ),
                          ),
                          const Spacer(),
                          if (_status != null) ...[
                            Flexible(
                              child: Text(
                                _status!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.right,
                                style: body(12, color: _statusColor),
                              ),
                            ),
                            const SizedBox(width: 12),
                          ],
                          Opacity(
                            opacity: _busy ? 0.6 : 1,
                            child: HoverSurface(
                              onTap: _busy ? null : _save,
                              radius: 999,
                              background: Serene.primary,
                              hoverBackground: const Color(0xE63D6A4B),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 10,
                              ),
                              child: Text(
                                'Kaydet',
                                style: body(
                                  13,
                                  weight: FontWeight.w500,
                                  color: Serene.onPrimary,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sayi alani: `min`/`max` niteliklerinin karsiligi 1..16 arasi tam sayi.
class _NumberField extends StatelessWidget {
  const _NumberField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: Serene.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Serene.radiusField),
        border: Border.all(color: const Color(0x99DCD8CE)),
      ),
      child: TextField(
        controller: controller,
        cursorColor: Serene.primary,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: body(13),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
        ),
      ),
    );
  }
}

/// Etiket + alt aciklama + kutucuk; webdeki `label` satirlarinin karsiligi.
class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.title,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return HoverSurface(
      onTap: () => onChanged(!value),
      background: Serene.surfaceContainerLow,
      hoverBackground: Serene.surfaceContainerLow,
      radius: Serene.radiusTile,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      border: Border.all(color: Serene.outlineVariant.withValues(alpha: 0.5)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: body(13, weight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: body(11, color: Serene.secondary, height: 1.35),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 24,
            height: 24,
            child: FittedBox(
              child: Checkbox(
                value: value,
                onChanged: (next) => onChanged(next ?? false),
                activeColor: Serene.primary,
                checkColor: Serene.onPrimary,
                side: const BorderSide(color: Serene.outline),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CloseSettings extends Intent {
  const _CloseSettings();
}

/// Web arayuzundeki sayi alanlarinin davranisi: bos ya da gecersiz girdi
/// mevcut degeri korur, `min`/`max` niteliginin yerine 1..16 kisiti gecilir.
int parseCount(String? text, int fallback) {
  final value = int.tryParse((text ?? '').trim());
  if (value == null) return fallback;
  if (value < 1) return 1;
  if (value > 16) return 16;
  return value;
}
