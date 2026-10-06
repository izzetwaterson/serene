import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'strings.dart';
import 'theme.dart';
import 'widgets.dart';

/// Kurulum paketiyle gelen eklenti klasoru; exe'nin yaninda durur.
///
/// Gelistirme derlemelerinde klasor yoktur; bu yuzden tanitim penceresi
/// kendiliginden yalnizca gercek pakette gorunur.
Directory? extensionFolder() {
  final exeDir = File(Platform.resolvedExecutable).parent;
  final folder = Directory(
    '${exeDir.path}${Platform.pathSeparator}extension',
  );
  if (!folder.existsSync()) return null;
  return folder;
}

/// Ilk acilis tanitimi: eklenti klasorunu acar, kurulum adimlarini gosterir.
///
/// `browserUp` köprü durumunu tasir; eklenti pencere acikken baglanirsa
/// rozet "Baglandi" durumuna gecer ve pencere kisa bir sure sonra kapanir.
class ExtensionOfferDialog extends StatefulWidget {
  const ExtensionOfferDialog({
    super.key,
    required this.browserUp,
    required this.folder,
  });

  final ValueListenable<bool> browserUp;
  final Directory folder;

  @override
  State<ExtensionOfferDialog> createState() => _ExtensionOfferDialogState();
}

class _ExtensionOfferDialogState extends State<ExtensionOfferDialog> {
  bool _connected = false;
  Timer? _close;

  @override
  void initState() {
    super.initState();
    widget.browserUp.addListener(_onBridge);
    _onBridge();
  }

  @override
  void dispose() {
    _close?.cancel();
    widget.browserUp.removeListener(_onBridge);
    super.dispose();
  }

  void _onBridge() {
    if (!widget.browserUp.value || _connected) return;
    setState(() => _connected = true);
    _close = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  /// `explorer /select` manifest'i isaretler. Kesme isareti Explorer'in kendi
  /// komut satiri ayristirmasi icin gerekli; iki argumanli bicim bunu saglar.
  Future<void> _openFolder() async {
    final manifest =
        '${widget.folder.path}${Platform.pathSeparator}manifest.json';
    try {
      final result = await Process.run('explorer.exe', ['/select,', manifest]);
      if (result.exitCode == 0) return;
    } catch (_) {
      /* asagida klasorun kendisi denenir */
    }
    try {
      await Process.run('explorer.exe', [widget.folder.path]);
    } catch (_) {
      /* gezgin acilamazsa pencere acik kalir; adimlar hala gorunur */
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        width: 460,
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: Serene.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(Serene.radiusCard),
          border: Border.all(color: Serene.borderInput),
          boxShadow: Serene.shadowFloat,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Serene.tintPrimary,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: SIcon(
                      'travel_explore',
                      size: 22,
                      color: Serene.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    T.extensionOfferTitle,
                    style: head(19, weight: FontWeight.w500),
                  ),
                ),
                StatusChip(
                  label: T.extensionOfferBadge,
                  background: Serene.tintPrimary,
                  foreground: Serene.primary,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              T.extensionOfferBody,
              style: body(13.5, color: Serene.onSurfaceVariant, height: 1.45),
            ),
            const SizedBox(height: 16),
            _Step(number: 1, text: T.extensionOfferStep1),
            const SizedBox(height: 10),
            _Step(number: 2, text: T.extensionOfferStep2),
            const SizedBox(height: 14),
            Text(
              T.extensionOfferNote,
              style: body(12, color: Serene.outline, height: 1.4),
            ),
            const SizedBox(height: 22),
            if (_connected)
              Row(
                children: [
                  SIcon('check_circle', size: 18, color: Serene.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      T.extensionOfferConnected,
                      style: body(
                        13.5,
                        weight: FontWeight.w600,
                        color: Serene.primary,
                      ),
                    ),
                  ),
                ],
              )
            else
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 10,
                runSpacing: 10,
                children: [
                  HoverSurface(
                    onTap: () => Navigator.of(context).pop(),
                    background: Serene.surfaceContainer,
                    hoverBackground: Serene.surfaceContainerHigh,
                    radius: Serene.radiusField,
                    border: Border.all(color: Serene.borderInput),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Text(
                      T.extensionOfferLater,
                      style: body(
                        13,
                        weight: FontWeight.w600,
                        color: Serene.secondary,
                      ),
                    ),
                  ),
                  HoverSurface(
                    onTap: _openFolder,
                    background: Serene.primary,
                    hoverBackground: Serene.primaryHover,
                    radius: Serene.radiusField,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SIcon('folder_open', size: 16, color: Serene.onPrimary),
                        const SizedBox(width: 8),
                        Text(
                          T.extensionOfferOpen,
                          style: body(
                            13,
                            weight: FontWeight.w600,
                            color: Serene.onPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Numarali adim satiri.
class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Serene.surfaceContainer,
            shape: BoxShape.circle,
            border: Border.all(color: Serene.borderInput),
          ),
          child: Center(
            child: Text('$number', style: mono(10, color: Serene.secondary)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: body(13, height: 1.45))),
      ],
    );
  }
}
