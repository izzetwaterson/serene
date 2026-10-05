import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'controller.dart';
import 'setup_logic.dart';
import 'strings.dart';
import 'theme.dart';
import 'widgets.dart';

/// Kurulum penceresi: kucuk ve yatay.
const Size setupWindowSize = Size(560, 420);

/// Icerik sutunu genisligi.
const double _contentWidth = 472;

/// Bir sayfanin icerigi.
class PageSpec {
  const PageSpec({required this.title, this.subtitle, required this.body, this.actions = const [], this.leading});

  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget> actions;

  /// Dugme satirinin solunda duran kucuk bilgi (ornegin surum).
  final Widget? leading;
}

/// Pencere iskeleti: quiz yerlesimi + surukleme alani + kapat dugmesi.
class SetupShell extends StatelessWidget {
  const SetupShell({super.key, required this.controller});

  final SetupController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final spec = _specFor(c, L.current);
    return Container(
      decoration: BoxDecoration(color: Serene.background, border: Border.all(color: Serene.outlineVariant)),
      child: Stack(
        children: [
          Positioned.fill(child: _QuizLayout(c: c, spec: spec)),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 38,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => windowManager.startDragging(),
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 6, 8, 0),
                  child: CloseDot(onTap: c.busy ? null : () => exit(0)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sayfa degisince yalniz degisen kisim yumusakca gecer; nokta gostergesi
/// yerinde kalir.
class _Swap extends StatelessWidget {
  const _Swap({required this.page, required this.child});

  final SetupPage page;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topLeft,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey(page), child: child),
    );
  }
}

/* ---------- quiz yerlesimi ---------- */

/// Tek soru: her ekran tek bir sey sorar; nokta gostergesi yolu gosterir.
class _QuizLayout extends StatelessWidget {
  const _QuizLayout({required this.c, required this.spec});

  final SetupController c;
  final PageSpec spec;

  /// Kaldirma yolu kurulumdan ayri ve kisa: onay, kaldirma, bitti.
  bool get _uninstallFlow =>
      c.page == SetupPage.confirmUninstall ||
      c.page == SetupPage.removing ||
      c.page == SetupPage.removed ||
      (c.page == SetupPage.error && c.args.uninstall);

  int get _total => _uninstallFlow ? 2 : 4;

  int get _step {
    switch (c.page) {
      case SetupPage.language:
        return 0;
      case SetupPage.welcome:
        return 1;
      case SetupPage.options:
        return 2;
      case SetupPage.confirmUninstall:
        return 0;
      case SetupPage.removing:
      case SetupPage.removed:
        return 1;
      default:
        return _uninstallFlow ? 1 : 3;
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = _step;
    return Padding(
      padding: const EdgeInsets.fromLTRB(44, 40, 44, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FadeSlideIn(
            child: Row(
              children: [
                for (var i = 0; i < _total; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    width: i == step ? 22 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: i <= step ? Serene.primary : Serene.outlineVariant,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
                const Spacer(),
                Text('0${step + 1} / 0$_total', style: mono(10.5, color: Serene.onSurfaceVariant).copyWith(letterSpacing: 1.2)),
              ],
            ),
          ),
          const Spacer(flex: 2),
          _Swap(
            page: c.page,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (c.page == SetupPage.done || c.page == SetupPage.removed) ...[
                  const LeafImage(size: 24),
                  const SizedBox(height: 14),
                ],
                _TitleBlock(
                    spec: spec,
                    titleSize: c.page == SetupPage.done || c.page == SetupPage.removed ? 40 : 26),
                const SizedBox(height: 18),
                spec.body,
              ],
            ),
          ),
          const Spacer(flex: 3),
          _quizActions(spec),
        ],
      ),
    );
  }

  /// Eylemler: tek dugme sagda; ikiliyse geri solda, ana eylem sagda.
  Widget _quizActions(PageSpec spec) {
    final children = <Widget>[
      if (spec.leading != null) spec.leading!,
      for (var i = 0; i < spec.actions.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        spec.actions[i],
      ],
    ];
    if (children.isEmpty) return const SizedBox(height: 4);
    return FadeSlideIn(
      delayMs: 220,
      child: Row(
        mainAxisAlignment: children.length > 1 ? MainAxisAlignment.spaceBetween : MainAxisAlignment.end,
        children: children,
      ),
    );
  }
}

/// Quiz "Nereye kurulsun?" cevabi: buyuk yol + degistir baglantisi.
class _QuizFolder extends StatefulWidget {
  const _QuizFolder({required this.c, required this.t});

  final SetupController c;
  final L t;

  @override
  State<_QuizFolder> createState() => _QuizFolderState();
}

class _QuizFolderState extends State<_QuizFolder> {
  bool _hover = false;

  Future<void> _pick() async {
    final picked = await FilePicker.getDirectoryPath(dialogTitle: widget.t.pickFolder);
    if (picked != null) widget.c.setDir(normalizeInstallDir(picked));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.c.options.dir, maxLines: 2, overflow: TextOverflow.ellipsis, style: mono(15, color: Serene.onSurface)),
        const SizedBox(height: 8),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: _pick,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                widget.t.change,
                style: body(13, weight: FontWeight.w600, color: _hover ? Serene.primary : Serene.onSurfaceVariant),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Quiz sessiz geri baglantisi: ok + etiket, zemin yok.
class _QuizBack extends StatefulWidget {
  const _QuizBack({required this.label, this.onTap, this.showArrow = true});

  final String label;
  final VoidCallback? onTap;
  final bool showArrow;

  @override
  State<_QuizBack> createState() => _QuizBackState();
}

class _QuizBackState extends State<_QuizBack> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final color = !enabled ? Serene.outlineVariant : (_hover ? Serene.primary : Serene.onSurfaceVariant);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.showArrow) ...[
                Icon(Icons.arrow_back_rounded, size: 15, color: color),
                const SizedBox(width: 6),
              ],
              Text(widget.label, style: body(13, weight: FontWeight.w600, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Quiz dil secimi: serif ad, satir sonunda kare isaret.
class _QuizLangRow extends StatefulWidget {
  const _QuizLangRow({required this.name, required this.selected, required this.onTap});

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_QuizLangRow> createState() => _QuizLangRowState();
}

class _QuizLangRowState extends State<_QuizLangRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          child: Row(
            children: [
              Expanded(
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 180),
                  style: head(20, weight: FontWeight.w500, color: sel || _hover ? Serene.primary : Serene.onBackground),
                  child: Text(widget.name),
                ),
              ),
              _CheckBox(on: sel),
            ],
          ),
        ),
      ),
    );
  }
}

/// Kare isaret kutusu.
class _CheckBox extends StatelessWidget {
  const _CheckBox({required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: on ? Serene.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: on ? Colors.transparent : Serene.outlineVariant, width: 1.5),
      ),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: on ? 1 : 0,
        child: Icon(Icons.check_rounded, size: 14, color: Serene.onPrimary),
      ),
    );
  }
}

/// Quiz secenek satiri: kare kutu + etiket + istege bagli alt ipucu.
class _CheckRow extends StatefulWidget {
  const _CheckRow({required this.title, required this.value, required this.onChanged, this.hint});

  final String title;
  final String? hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<_CheckRow> createState() => _CheckRowState();
}

class _CheckRowState extends State<_CheckRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onChanged(!widget.value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: _CheckBox(on: widget.value)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.title, style: body(14.5, weight: FontWeight.w600, color: _hover ? Serene.onBackground : Serene.onSurface)),
                    if (widget.hint != null) ...[
                      const SizedBox(height: 2),
                      Text(widget.hint!, style: body(11.5, color: Serene.onSurfaceVariant, height: 1.3)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ---------- ortak parcalar ---------- */

class _TitleBlock extends StatelessWidget {
  const _TitleBlock({required this.spec, this.titleSize = 22});

  final PageSpec spec;
  final double titleSize;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeSlideIn(
          child: Text(spec.title, style: head(titleSize, weight: FontWeight.w500, height: 1.15)),
        ),
        if (spec.subtitle != null) ...[
          const SizedBox(height: 6),
          FadeSlideIn(
            delayMs: 90,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Text(spec.subtitle!, style: body(12.5, color: Serene.onSurfaceVariant, height: 1.5)),
            ),
          ),
        ],
      ],
    );
  }
}

class _RunningCard extends StatelessWidget {
  const _RunningCard({required this.c, required this.t});

  final SetupController c;
  final L t;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: Serene.tintTertiary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Serene.tertiary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: Serene.tertiary, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.runningTitle, style: body(12.5, weight: FontWeight.w700)),
                const SizedBox(height: 1),
                Text(t.runningBody, style: body(11, color: Serene.onSurfaceVariant, height: 1.35)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SButton(label: t.closeSerene, onTap: c.closeSerene, primary: false, compact: true),
        ],
      ),
    );
  }
}

String _stepLabel(L t, SetupStep step) {
  switch (step) {
    case SetupStep.files:
      return t.stepFiles;
    case SetupStep.register:
      return t.stepRegister;
    case SetupStep.shortcut:
      return t.stepShortcut;
    case SetupStep.desktop:
      return t.stepDesktop;
    case SetupStep.autostart:
      return t.stepAutostart;
    case SetupStep.done:
      return t.stepDone;
    case SetupStep.removeBridge:
      return t.stepRemoveBridge;
    case SetupStep.removeFiles:
      return t.stepRemoveFiles;
    case SetupStep.removeRegistry:
      return t.stepRemoveRegistry;
    case SetupStep.removeData:
      return t.stepRemoveData;
  }
}

/* ---------- sayfa iceriklerini uret ---------- */

/// Quiz eylemi: dolgu dugme ya da sessiz geri baglantisi. `danger` yikici
/// eylemi kirmiziya cevirir.
Widget _actionFor(String label, VoidCallback? onTap, {bool primary = true, bool danger = false}) {
  if (primary) return SButton(label: label, onTap: onTap, danger: danger);
  return _QuizBack(label: label, onTap: onTap);
}

PageSpec _specFor(SetupController c, L t) {
  switch (c.page) {
    case SetupPage.language:
      return PageSpec(
        title: t.languageTitle,
        subtitle: t.languageSubtitle,
        body: SizedBox(
          width: _contentWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _QuizLangRow(name: 'English', selected: !t.isTurkish, onTap: () => c.selectLanguage(false)),
              _QuizLangRow(name: 'Türkçe', selected: t.isTurkish, onTap: () => c.selectLanguage(true)),
            ],
          ),
        ),
        actions: [_actionFor(t.continueLabel, () => c.go(SetupPage.welcome))],
      );

    case SetupPage.welcome:
      final missing = !c.installer.payloadPresent;
      return PageSpec(
        title: t.whereTitle,
        body: SizedBox(
          width: _contentWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _QuizFolder(c: c, t: t),
              if (c.sereneRunning) ...[const SizedBox(height: 14), _RunningCard(c: c, t: t)],
              if (missing) ...[
                const SizedBox(height: 8),
                Text('Setup files are missing:\n${c.installer.payloadDir}', style: mono(11, color: Serene.error)),
              ],
            ],
          ),
        ),
        actions: [
          _actionFor(t.back, () => c.go(SetupPage.language), primary: false),
          _actionFor(t.continueLabel, () => c.go(SetupPage.options)),
        ],
      );

    case SetupPage.options:
      return PageSpec(
        title: t.optionsTitle,
        body: SizedBox(
          width: _contentWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CheckRow(title: t.optStartMenu, hint: t.optStartMenuHint, value: c.options.startMenu, onChanged: c.toggleStartMenu),
              _CheckRow(title: t.optDesktop, hint: t.optDesktopHint, value: c.options.desktop, onChanged: c.toggleDesktop),
              _CheckRow(title: t.optAutostart, hint: t.optAutostartHint, value: c.options.autostart, onChanged: c.toggleAutostart),
              if (c.sereneRunning) ...[const SizedBox(height: 14), _RunningCard(c: c, t: t)],
            ],
          ),
        ),
        actions: [
          _actionFor(t.back, () => c.go(SetupPage.welcome), primary: false),
          _actionFor(t.install, c.sereneRunning ? null : c.startInstall),
        ],
      );

    case SetupPage.installing:
      return PageSpec(title: t.installingTitle, body: _progressBody(c, t));

    case SetupPage.removing:
      return PageSpec(title: t.removingTitle, body: _progressBody(c, t));

    case SetupPage.done:
      return PageSpec(
        title: t.doneTitle,
        subtitle: t.doneBody,
        actions: [
          _QuizBack(label: t.finish, showArrow: false, onTap: () => c.finishWith(false)),
          _actionFor(t.launchSerene, () => c.finishWith(true)),
        ],
        body: const SizedBox.shrink(),
      );

    case SetupPage.error:
      final message = c.error == 'notInstalled' ? t.notInstalled : (c.error ?? '');
      return PageSpec(
        title: t.errorTitle,
        actions: [
          _actionFor(t.close, () => exit(0), primary: false),
          if (c.error != 'notInstalled')
            _actionFor(t.retry, c.args.uninstall ? c.startUninstall : () => c.go(SetupPage.welcome)),
        ],
        body: Container(
          width: _contentWidth,
          constraints: const BoxConstraints(maxHeight: 130),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Serene.errorContainer, borderRadius: BorderRadius.circular(12)),
          child: SingleChildScrollView(child: Text(message, style: mono(11, color: Serene.onErrorContainer))),
        ),
      );

    case SetupPage.confirmUninstall:
      return PageSpec(
        title: t.uninstallTitle,
        subtitle: t.uninstallBody,
        actions: [
          _actionFor(t.cancel, () => exit(0), primary: false),
          _actionFor(t.uninstall, c.sereneRunning ? null : c.startUninstall, danger: true),
        ],
        body: SizedBox(
          width: _contentWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CheckRow(title: t.keepData, hint: t.keepDataHint, value: c.keepData, onChanged: c.toggleKeepData),
              if (c.sereneRunning) ...[const SizedBox(height: 10), _RunningCard(c: c, t: t)],
            ],
          ),
        ),
      );

    case SetupPage.removed:
      return PageSpec(
        title: t.removedTitle,
        subtitle: t.removedBody,
        actions: [_actionFor(t.finish, c.finish)],
        body: const SizedBox.shrink(),
      );
  }
}

/// Ilerleme govdesi: buyuk serif yuzde, adim etiketi, ince cubuk ve dosya yolu.
Widget _progressBody(SetupController c, L t) {
  return SizedBox(
    width: _contentWidth,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        TweenAnimationBuilder<double>(
          tween: Tween(end: c.progress),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (context, value, _) => Text('${(value * 100).round()}%', style: head(42, weight: FontWeight.w500, height: 1.05)),
        ),
        const SizedBox(height: 8),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: Align(
            key: ValueKey(c.step),
            alignment: Alignment.centerLeft,
            child: Text(_stepLabel(t, c.step), style: body(13.5, color: Serene.onSurfaceVariant)),
          ),
        ),
        const SizedBox(height: 16),
        SoftProgress(value: c.progress),
        const SizedBox(height: 10),
        SizedBox(height: 16, child: Text(c.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(10.5))),
      ],
    ),
  );
}
