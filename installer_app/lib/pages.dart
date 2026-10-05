import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'controller.dart';
import 'setup_logic.dart';
import 'strings.dart';
import 'theme.dart';
import 'widgets.dart';

/// Pencere boyutu varyanta gore. Hepsi kucuk ve yatay.
Size windowSizeFor(SetupVariant v) {
  switch (v) {
    case SetupVariant.card:
      return const Size(640, 360);
    case SetupVariant.calm:
      return const Size(520, 400);
    case SetupVariant.flow:
      return const Size(620, 500);
    case SetupVariant.editorial:
      return const Size(640, 480);
    case SetupVariant.mini:
      return const Size(460, 300);
    case SetupVariant.wizard:
      return const Size(720, 440);
    case SetupVariant.quiz:
      return const Size(560, 420);
    case SetupVariant.fluent:
      return const Size(620, 400);
  }
}

/// Bir sayfanin icerigi; yerlesimi varyant belirler.
class PageSpec {
  const PageSpec({required this.title, this.subtitle, required this.body, this.actions = const [], this.leading});

  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget> actions;

  /// Dugme satirinin solunda duran kucuk bilgi (ornegin surum).
  final Widget? leading;
}

/// Pencere iskeleti: varyanta gore yerlesim + surukleme alani + kapat dugmesi.
class SetupShell extends StatelessWidget {
  const SetupShell({super.key, required this.controller});

  final SetupController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final spec = _specFor(c, L.current);
    final Widget layout;
    switch (c.variant) {
      case SetupVariant.card:
        layout = _CardLayout(c: c, spec: spec);
      case SetupVariant.calm:
        layout = _CalmLayout(c: c, spec: spec);
      case SetupVariant.flow:
        layout = _FlowLayout(c: c, spec: spec);
      case SetupVariant.editorial:
        layout = _EditorialLayout(c: c, spec: spec);
      case SetupVariant.mini:
        layout = _MiniLayout(c: c, spec: spec);
      case SetupVariant.wizard:
        layout = _WizardLayout(c: c, spec: spec);
      case SetupVariant.quiz:
        layout = _QuizLayout(c: c, spec: spec);
      case SetupVariant.fluent:
        layout = _FluentLayout(c: c, spec: spec);
    }
    return Container(
      decoration: BoxDecoration(color: Serene.background, border: Border.all(color: Serene.outlineVariant)),
      child: Stack(
        children: [
          Positioned.fill(child: layout),
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

/// Sayfa degisince yalniz degisen kisim yumusakca gecer; marka alani yerinde kalir.
class _Swap extends StatelessWidget {
  const _Swap({required this.page, required this.child, this.alignment = Alignment.topLeft, this.morph = false});

  final SetupPage page;
  final Widget child;
  final Alignment alignment;

  /// `true` ise icerik yatay kaymaz; dikey yumusak donusumle akar (flow).
  final bool morph;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: Duration(milliseconds: morph ? 420 : 340),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (current, previous) => Stack(
        alignment: alignment,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) {
        final begin = morph ? const Offset(0, 0.05) : const Offset(0.025, 0);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(begin: begin, end: Offset.zero).animate(animation),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(key: ValueKey(page), child: child),
    );
  }
}

/* ---------- varyant A: card ---------- */

class _CardLayout extends StatelessWidget {
  const _CardLayout({required this.c, required this.spec});

  final SetupController c;
  final PageSpec spec;

  @override
  Widget build(BuildContext context) {
    final t = L.current;
    return Row(
      children: [
        Container(
          width: 190,
          decoration: BoxDecoration(
            color: Serene.primaryFixed.withValues(alpha: 0.5),
            border: Border(right: BorderSide(color: Serene.outlineVariant.withValues(alpha: 0.7))),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              LeafMark(progress: c.ringProgress, size: 120),
              const SizedBox(height: 6),
              FadeSlideIn(delayMs: 250, child: Text('Serene', style: head(24, weight: FontWeight.w500, letterSpacing: -0.3))),
              const SizedBox(height: 4),
              FadeSlideIn(
                delayMs: 380,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Text(t.tagline, textAlign: TextAlign.center, style: body(11, color: Serene.onSurfaceVariant, height: 1.4)),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _Swap(
            page: c.page,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 36, 32, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TitleBlock(spec: spec, titleSize: 22),
                  const SizedBox(height: 14),
                  Expanded(child: FadeSlideIn(delayMs: 160, child: Align(alignment: Alignment.topLeft, child: spec.body))),
                  _ActionRow(spec: spec, alignment: MainAxisAlignment.end),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/* ---------- varyant B: calm ---------- */

class _CalmLayout extends StatelessWidget {
  const _CalmLayout({required this.c, required this.spec});

  final SetupController c;
  final PageSpec spec;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 22, 40, 20),
      child: Column(
        children: [
          LeafMark(progress: c.ringProgress, size: 84),
          Expanded(
            child: _Swap(
              page: c.page,
              alignment: Alignment.topCenter,
              child: Column(
                children: [
                  _TitleBlock(spec: spec, centered: true, titleSize: 23),
                  const SizedBox(height: 12),
                  Expanded(
                    child: FadeSlideIn(
                      delayMs: 160,
                      child: Align(alignment: Alignment.topCenter, child: spec.body),
                    ),
                  ),
                  _ActionRow(spec: spec, alignment: MainAxisAlignment.center),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/* ---------- varyant C: flow ---------- */

class _FlowLayout extends StatelessWidget {
  const _FlowLayout({required this.c, required this.spec});

  final SetupController c;
  final PageSpec spec;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Icerik yuzeyi: sayfalar bu panelin icinde donusur, pencere sabit kalir.
        Positioned(
          top: 46,
          left: 44,
          right: 44,
          bottom: 24,
          child: Container(
            padding: const EdgeInsets.fromLTRB(26, 64, 26, 18),
            decoration: BoxDecoration(
              color: Serene.surfaceLowest,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Serene.outlineVariant.withValues(alpha: 0.6)),
              boxShadow: Serene.shadowFloat,
            ),
            child: _Swap(
              page: c.page,
              alignment: Alignment.topCenter,
              morph: true,
              child: Column(
                children: [
                  _TitleBlock(spec: spec, centered: true, titleSize: 23),
                  const SizedBox(height: 12),
                  Expanded(
                    child: FadeSlideIn(
                      delayMs: 160,
                      child: Align(alignment: Alignment.topCenter, child: spec.body),
                    ),
                  ),
                  _ActionRow(spec: spec, alignment: MainAxisAlignment.center),
                ],
              ),
            ),
          ),
        ),
        // Madalyon yaprak: panelin ust kenarina oturur; halka ilerlemeyi tasir.
        Positioned(
          top: 6,
          left: 0,
          right: 0,
          child: Align(alignment: Alignment.topCenter, child: LeafMark(progress: c.ringProgress, size: 96)),
        ),
      ],
    );
  }
}

/* ---------- varyant D: editorial ---------- */

/// Kart yok: marka serifi ve ince cizgiler dogrudan zeminde durur;
/// sayfalar ayni kagit uzerinde yumusakca degisir.
class _EditorialLayout extends StatelessWidget {
  const _EditorialLayout({required this.c, required this.spec});

  final SetupController c;
  final PageSpec spec;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(52, 40, 52, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FadeSlideIn(
            child: Row(
              children: [
                LeafImage(size: 19),
                const SizedBox(width: 9),
                Text('Serene', style: head(15, weight: FontWeight.w500, letterSpacing: 0.2)),
              ],
            ),
          ),
          const SizedBox(height: 36),
          Expanded(
            child: _Swap(
              page: c.page,
              morph: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TitleBlock(spec: spec, titleSize: 27),
                  const SizedBox(height: 16),
                  Expanded(
                    child: FadeSlideIn(
                      delayMs: 160,
                      child: Align(alignment: Alignment.topLeft, child: spec.body),
                    ),
                  ),
                  _ActionRow(spec: spec, alignment: MainAxisAlignment.end),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Editoryal parcalar: metin eylemi, dil secimi, klasor satiri, uyari satiri,
/// ince ayirici ve ince ilerleme cizgisi.
class _LinkAction extends StatefulWidget {
  const _LinkAction({required this.label, this.onTap, this.primary = true, this.danger = false});

  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool danger;

  @override
  State<_LinkAction> createState() => _LinkActionState();
}

class _LinkActionState extends State<_LinkAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final Color color;
    if (!enabled) {
      color = Serene.outlineVariant;
    } else if (widget.primary && widget.danger) {
      color = _hover ? Color.lerp(Serene.error, Colors.black, 0.16)! : Serene.error;
    } else if (widget.primary) {
      color = _hover ? Serene.primaryHover : Serene.primary;
    } else {
      color = _hover ? Serene.onSurface : Serene.onSurfaceVariant;
    }
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          child: Text(
            widget.primary ? '${widget.label} →' : widget.label,
            style: body(13.5, weight: FontWeight.w700, color: color),
          ),
        ),
      ),
    );
  }
}

class _LangLink extends StatefulWidget {
  const _LangLink({required this.name, required this.selected, required this.onTap});

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_LangLink> createState() => _LangLinkState();
}

class _LangLinkState extends State<_LangLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 180),
                style: head(19, weight: FontWeight.w500, color: sel || _hover ? Serene.primary : Serene.onBackground),
                child: Text(widget.name),
              ),
              const SizedBox(width: 7),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: sel ? 1 : 0,
                child: Icon(Icons.check_rounded, size: 17, color: Serene.primary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FolderRow extends StatefulWidget {
  const _FolderRow({required this.c, required this.t});

  final SetupController c;
  final L t;

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
  bool _hover = false;

  Future<void> _pick() async {
    final picked = await FilePicker.getDirectoryPath(dialogTitle: widget.t.pickFolder);
    if (picked != null) widget.c.setDir(normalizeInstallDir(picked));
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _pick,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Text(widget.t.installFolder, style: body(12.5, color: Serene.onSurfaceVariant)),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  widget.c.options.dir,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono(11.5, color: _hover ? Serene.primary : Serene.onSurface),
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right_rounded, size: 16, color: _hover ? Serene.primary : Serene.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _RunningLine extends StatelessWidget {
  const _RunningLine({required this.c, required this.t});

  final SetupController c;
  final L t;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.info_outline_rounded, color: Serene.tertiary, size: 17)),
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
        const SizedBox(width: 10),
        _LinkAction(label: t.closeSerene, onTap: c.closeSerene, primary: false),
      ],
    );
  }
}

class _Hair extends StatelessWidget {
  const _Hair();

  @override
  Widget build(BuildContext context) => Container(height: 1, color: Serene.outlineVariant);
}

class _HairProgress extends StatelessWidget {
  const _HairProgress({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 2,
      color: Serene.outlineVariant,
      alignment: Alignment.centerLeft,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: value.clamp(0.0, 1.0)),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => FractionallySizedBox(
          widthFactor: v,
          child: Container(color: Serene.primary),
        ),
      ),
    );
  }
}

/* ---------- varyant E: mini ---------- */

/// En kucuk pencere: yaprak + baslik satiri ve tek sayfa icerik;
/// ayarlar klasor satirinin altindaki "Ozellestir" ile satir ici acilir.
class _MiniLayout extends StatelessWidget {
  const _MiniLayout({required this.c, required this.spec});

  final SetupController c;
  final PageSpec spec;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 20, 26, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FadeSlideIn(
            child: Row(
              children: [
                LeafImage(size: 18),
                const SizedBox(width: 8),
                Text('Serene', style: head(14, weight: FontWeight.w500, letterSpacing: 0.2)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _Swap(
              page: c.page,
              morph: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TitleBlock(spec: spec, titleSize: 19),
                  const SizedBox(height: 8),
                  Expanded(
                    child: FadeSlideIn(
                      delayMs: 160,
                      child: Align(alignment: Alignment.topLeft, child: spec.body),
                    ),
                  ),
                  _ActionRow(spec: spec, alignment: MainAxisAlignment.end),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mini karsilama govdesi: klasor satiri + "Ozellestir" baglantisi; ayarlar
/// ayni yerde acilir. Kucuk pencerede tasarsa govde kaydirilabilir.
class _MiniWelcome extends StatefulWidget {
  const _MiniWelcome({required this.c, required this.t, required this.missing});

  final SetupController c;
  final L t;
  final bool missing;

  @override
  State<_MiniWelcome> createState() => _MiniWelcomeState();
}

class _MiniWelcomeState extends State<_MiniWelcome> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final t = widget.t;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FolderRow(c: c, t: t),
          _ExpandLink(open: _open, label: t.customize, onTap: () => setState(() => _open = !_open)),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _open
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ToggleRow(title: t.optStartMenu, hint: t.optStartMenuHint, value: c.options.startMenu, onChanged: c.toggleStartMenu, showHint: false),
                      ToggleRow(title: t.optDesktop, hint: t.optDesktopHint, value: c.options.desktop, onChanged: c.toggleDesktop, showHint: false),
                      ToggleRow(title: t.optAutostart, hint: t.optAutostartHint, value: c.options.autostart, onChanged: c.toggleAutostart, showHint: false),
                      const SizedBox(height: 4),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          if (c.sereneRunning) ...[const SizedBox(height: 8), _RunningLine(c: c, t: t)],
          if (widget.missing) ...[
            const SizedBox(height: 8),
            Text('Setup files are missing:\n${c.installer.payloadDir}', style: mono(11, color: Serene.error)),
          ],
        ],
      ),
    );
  }
}

/// Ayarlari acip kapatan metin baglantisi; ok yon degistirir.
class _ExpandLink extends StatefulWidget {
  const _ExpandLink({required this.open, required this.label, required this.onTap});

  final bool open;
  final String label;
  final VoidCallback onTap;

  @override
  State<_ExpandLink> createState() => _ExpandLinkState();
}

class _ExpandLinkState extends State<_ExpandLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = _hover ? Serene.primary : Serene.onSurfaceVariant;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedRotation(
                turns: widget.open ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                child: Icon(Icons.expand_more_rounded, size: 18, color: color),
              ),
              const SizedBox(width: 6),
              Text(widget.label, style: body(12.5, weight: FontWeight.w600, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

/* ---------- varyant F: wizard ---------- */

/// Klasik sihirbaz: solda numarali adim rayi, sagda aktif adimin sayfasi.
class _WizardLayout extends StatelessWidget {
  const _WizardLayout({required this.c, required this.spec});

  final SetupController c;
  final PageSpec spec;

  /// Sayfanin ray uzerindeki adimi (0..2).
  int get _step {
    switch (c.page) {
      case SetupPage.language:
      case SetupPage.confirmUninstall:
        return 0;
      case SetupPage.welcome:
      case SetupPage.options:
      case SetupPage.removing:
        return 1;
      default:
        return 2;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = L.current;
    final labels = c.args.uninstall
        ? [t.wizConfirm, t.wizRemove, t.wizDone]
        : [t.wizLang, t.wizSetup, t.wizDone];
    final step = _step;
    return Row(
      children: [
        Container(
          width: 196,
          decoration: BoxDecoration(
            color: Serene.surfaceLow,
            border: Border(right: BorderSide(color: Serene.outlineVariant)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(26, 30, 20, 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(height: 20),
                  _WizStep(n: i + 1, label: labels[i], active: i == step, done: i < step),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: _Swap(
            page: c.page,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(38, 42, 38, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TitleBlock(spec: spec, titleSize: 23),
                  const SizedBox(height: 14),
                  Expanded(
                    child: FadeSlideIn(
                      delayMs: 160,
                      child: Align(alignment: Alignment.topLeft, child: spec.body),
                    ),
                  ),
                  _ActionRow(spec: spec, alignment: MainAxisAlignment.end),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Ray uzerindeki adim: daire + etiket; aktif dolu, biten isaretli.
class _WizStep extends StatelessWidget {
  const _WizStep({required this.n, required this.label, required this.active, required this.done});

  final int n;
  final String label;
  final bool active;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final Color circle;
    final Color fg;
    if (done) {
      circle = Serene.primaryFixed;
      fg = Serene.primary;
    } else if (active) {
      circle = Serene.primary;
      fg = Serene.onPrimary;
    } else {
      circle = Colors.transparent;
      fg = Serene.onSurfaceVariant;
    }
    return Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: circle,
            border: Border.all(color: active || done ? Colors.transparent : Serene.outlineVariant),
          ),
          child: done ? Icon(Icons.check_rounded, size: 15, color: fg) : Text('$n', style: mono(12, color: fg)),
        ),
        const SizedBox(width: 12),
        Text(
          label,
          style: body(13.5,
              weight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? Serene.onBackground : (done ? Serene.onSurface : Serene.onSurfaceVariant)),
        ),
      ],
    );
  }
}

/* ---------- varyant G: quiz ---------- */

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
            morph: true,
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

/// Kare isaret kutusu (quiz ve fluent ortak cizim).
class _CheckBox extends StatelessWidget {
  const _CheckBox({required this.on, this.radius = 6});

  final bool on;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: on ? Serene.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(radius),
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

/* ---------- varyant H: fluent ---------- */

/// Fluent/Windows'a yerli: Segoe UI, kare koseler, sade Windows kontrolleri.
TextStyle seg(double size, {FontWeight weight = FontWeight.w400, Color? color, double? height}) => TextStyle(
      fontFamily: 'Segoe UI Variable Text',
      fontFamilyFallback: const ['Segoe UI'],
      fontSize: size,
      fontWeight: weight,
      color: color ?? Serene.onSurface,
      height: height,
    );

class _FluentLayout extends StatelessWidget {
  const _FluentLayout({required this.c, required this.spec});

  final SetupController c;
  final PageSpec spec;

  @override
  Widget build(BuildContext context) {
    final t = L.current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 60, 11),
          child: FadeSlideIn(
            child: Row(
              children: [
                LeafImage(size: 15),
                const SizedBox(width: 8),
                Text(t.setupTitle, style: seg(12.5, weight: FontWeight.w600)),
              ],
            ),
          ),
        ),
        Container(height: 1, color: Serene.outlineVariant),
        Expanded(
          child: _Swap(
            page: c.page,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _FluentTitleBlock(spec: spec),
                  const SizedBox(height: 16),
                  Expanded(
                    child: FadeSlideIn(
                      delayMs: 160,
                      child: Align(alignment: Alignment.topLeft, child: spec.body),
                    ),
                  ),
                  _ActionRow(spec: spec, alignment: MainAxisAlignment.end),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FluentTitleBlock extends StatelessWidget {
  const _FluentTitleBlock({required this.spec});

  final PageSpec spec;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeSlideIn(child: Text(spec.title, style: seg(19, weight: FontWeight.w600))),
        if (spec.subtitle != null) ...[
          const SizedBox(height: 6),
          FadeSlideIn(
            delayMs: 90,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Text(spec.subtitle!, style: seg(12.5, color: Serene.onSurfaceVariant, height: 1.45)),
            ),
          ),
        ],
      ],
    );
  }
}

/// Fluent dugme: accent (dolu) ya da standart (kenarlikli); kose yaricapi 4.
class _FluentButton extends StatefulWidget {
  const _FluentButton({required this.label, required this.onTap, this.accent = true, this.danger = false});

  final String label;
  final VoidCallback? onTap;
  final bool accent;
  final bool danger;

  @override
  State<_FluentButton> createState() => _FluentButtonState();
}

class _FluentButtonState extends State<_FluentButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final Color bg;
    final Color fg;
    final Border? border;
    if (widget.accent && widget.danger) {
      bg = enabled ? (_hover ? Color.lerp(Serene.error, Colors.black, 0.16)! : Serene.error) : Serene.outlineVariant;
      fg = enabled ? (Serene.brightness == Brightness.dark ? const Color(0xFF33110F) : Colors.white) : Serene.onSurfaceVariant;
      border = null;
    } else if (widget.accent) {
      bg = enabled ? (_hover ? Serene.primaryHover : Serene.primary) : Serene.outlineVariant;
      fg = enabled ? Serene.onPrimary : Serene.onSurfaceVariant;
      border = null;
    } else {
      bg = _hover && enabled ? Serene.surfaceContainer : Serene.surfaceLowest;
      fg = enabled ? Serene.onSurface : Serene.onSurfaceVariant;
      border = Border.all(color: Serene.outlineVariant);
    }
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4), border: border),
          child: Text(widget.label, style: seg(12.5, weight: FontWeight.w600, color: fg)),
        ),
      ),
    );
  }
}

/// Fluent klasor alani: kenarlikli kutu + "Gozat..." dugmesi.
class _FluentFolderField extends StatefulWidget {
  const _FluentFolderField({required this.c, required this.t});

  final SetupController c;
  final L t;

  @override
  State<_FluentFolderField> createState() => _FluentFolderFieldState();
}

class _FluentFolderFieldState extends State<_FluentFolderField> {
  Future<void> _pick() async {
    final picked = await FilePicker.getDirectoryPath(dialogTitle: widget.t.pickFolder);
    if (picked != null) widget.c.setDir(normalizeInstallDir(picked));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: Serene.surfaceLowest,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Serene.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(widget.c.options.dir, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(11.5, color: Serene.onSurface)),
          ),
          const SizedBox(width: 8),
          _FluentButton(label: widget.t.browse, onTap: _pick, accent: false),
        ],
      ),
    );
  }
}

/// Fluent onay satiri: kare kutu + Segoe etiket.
class _FluentCheckRow extends StatefulWidget {
  const _FluentCheckRow({required this.title, required this.value, required this.onChanged});

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<_FluentCheckRow> createState() => _FluentCheckRowState();
}

class _FluentCheckRowState extends State<_FluentCheckRow> {
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
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
          child: Row(
            children: [
              _CheckBox(on: widget.value, radius: 4),
              const SizedBox(width: 11),
              Text(widget.title, style: seg(13.5, color: _hover ? Serene.onBackground : Serene.onSurface)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fluent radyo satiri (dil secimi).
class _FluentRadioRow extends StatefulWidget {
  const _FluentRadioRow({required this.name, required this.selected, required this.onTap});

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_FluentRadioRow> createState() => _FluentRadioRowState();
}

class _FluentRadioRowState extends State<_FluentRadioRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 20,
                height: 20,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.selected ? Serene.primary : Serene.onSurfaceVariant,
                    width: widget.selected ? 2 : 1.5,
                  ),
                ),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 160),
                  opacity: widget.selected ? 1 : 0,
                  child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: Serene.primary)),
                ),
              ),
              const SizedBox(width: 11),
              Text(widget.name, style: seg(14, color: _hover ? Serene.onBackground : Serene.onSurface)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fluent ilerleme cubugu: 4px, kare kenarli dolgu.
class _FluentProgress extends StatelessWidget {
  const _FluentProgress({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: Container(
        height: 4,
        color: Serene.surfaceContainer,
        alignment: Alignment.centerLeft,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: value.clamp(0.0, 1.0)),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => FractionallySizedBox(
            widthFactor: v,
            child: Container(color: Serene.primary),
          ),
        ),
      ),
    );
  }
}

/* ---------- ortak parcalar ---------- */

class _TitleBlock extends StatelessWidget {
  const _TitleBlock({required this.spec, this.centered = false, this.titleSize = 22});

  final PageSpec spec;
  final bool centered;
  final double titleSize;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeSlideIn(
          child: Text(spec.title,
              textAlign: centered ? TextAlign.center : TextAlign.start,
              style: head(titleSize, weight: FontWeight.w500, height: 1.15)),
        ),
        if (spec.subtitle != null) ...[
          const SizedBox(height: 6),
          FadeSlideIn(
            delayMs: 90,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Text(spec.subtitle!,
                  textAlign: centered ? TextAlign.center : TextAlign.start,
                  style: body(12.5, color: Serene.onSurfaceVariant, height: 1.5)),
            ),
          ),
        ],
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.spec, required this.alignment});

  final PageSpec spec;
  final MainAxisAlignment alignment;

  @override
  Widget build(BuildContext context) {
    if (spec.actions.isEmpty && spec.leading == null) return const SizedBox(height: 4);
    final buttons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [for (var i = 0; i < spec.actions.length; i++) ...[if (i > 0) const SizedBox(width: 8), spec.actions[i]]],
    );
    return FadeSlideIn(
      delayMs: 220,
      child: alignment == MainAxisAlignment.center || spec.leading == null
          ? Row(mainAxisAlignment: alignment, children: [buttons])
          : Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [spec.leading!, buttons]),
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

class _FolderField extends StatelessWidget {
  const _FolderField({required this.c, required this.t});

  final SetupController c;
  final L t;

  Future<void> _pick() async {
    final picked = await FilePicker.getDirectoryPath(dialogTitle: t.pickFolder);
    if (picked != null) c.setDir(normalizeInstallDir(picked));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: Serene.surfaceLowest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Serene.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(child: Text(c.options.dir, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(11, color: Serene.onSurface))),
          const SizedBox(width: 6),
          SButton(label: t.change, onTap: _pick, primary: false, compact: true),
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

/// Icerik genisligi: kart varyantinda sag sutun, digerlerinde ortalanmis
/// sutun; editoryal varyantta tam ic genislik.
double _bodyWidth(SetupController c) {
  switch (c.variant) {
    case SetupVariant.card:
      return 376;
    case SetupVariant.calm:
      return 420;
    case SetupVariant.flow:
      return 430;
    case SetupVariant.editorial:
      return 536;
    case SetupVariant.mini:
      return 408;
    case SetupVariant.wizard:
      return 448;
    case SetupVariant.quiz:
      return 472;
    case SetupVariant.fluent:
      return 572;
  }
}

/// Varyanta gore eylem: editoryal sayfada metin eylemi, fluent'te Windows
/// dugmesi, digerlerinde yuvarlak dugme. `danger` yikici eylemi kirmiziya cevirir.
Widget _actionFor(SetupController c, String label, VoidCallback? onTap, {bool primary = true, bool danger = false}) {
  switch (c.variant) {
    case SetupVariant.editorial:
      return _LinkAction(label: label, onTap: onTap, primary: primary, danger: danger);
    case SetupVariant.quiz:
      if (primary) return SButton(label: label, onTap: onTap, danger: danger);
      return _QuizBack(label: label, onTap: onTap);
    case SetupVariant.fluent:
      return _FluentButton(label: label, onTap: onTap, accent: primary, danger: danger);
    default:
      return SButton(label: label, onTap: onTap, primary: primary, danger: danger);
  }
}

PageSpec _specFor(SetupController c, L t) {
  final calm = c.variant == SetupVariant.calm;
  final flow = c.variant == SetupVariant.flow;
  final editorial = c.variant == SetupVariant.editorial;
  final mini = c.variant == SetupVariant.mini;
  final wizard = c.variant == SetupVariant.wizard;
  final quiz = c.variant == SetupVariant.quiz;
  final fluent = c.variant == SetupVariant.fluent;
  final w = _bodyWidth(c);
  switch (c.page) {
    case SetupPage.language:
      return PageSpec(
        title: t.languageTitle,
        subtitle: t.languageSubtitle,
        body: SizedBox(
          width: w,
          child: quiz
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _QuizLangRow(name: 'English', selected: !t.isTurkish, onTap: () => c.selectLanguage(false)),
                    _QuizLangRow(name: 'Türkçe', selected: t.isTurkish, onTap: () => c.selectLanguage(true)),
                  ],
                )
              : fluent
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _FluentRadioRow(name: 'English', selected: !t.isTurkish, onTap: () => c.selectLanguage(false)),
                        _FluentRadioRow(name: 'Türkçe', selected: t.isTurkish, onTap: () => c.selectLanguage(true)),
                      ],
                    )
                  : editorial
                      ? Row(
                          children: [
                            _LangLink(name: 'English', selected: !t.isTurkish, onTap: () => c.selectLanguage(false)),
                            const SizedBox(width: 32),
                            _LangLink(name: 'Türkçe', selected: t.isTurkish, onTap: () => c.selectLanguage(true)),
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(child: LangCard(code: 'EN', name: 'English', selected: !t.isTurkish, onTap: () => c.selectLanguage(false))),
                            const SizedBox(width: 10),
                            Expanded(child: LangCard(code: 'TR', name: 'Türkçe', selected: t.isTurkish, onTap: () => c.selectLanguage(true))),
                          ],
                        ),
        ),
        actions: [_actionFor(c, t.continueLabel, () => c.go(SetupPage.welcome))],
      );

    case SetupPage.welcome:
      final missing = !c.installer.payloadPresent;
      // quiz: klasor ayri bir soru ekranidir.
      if (quiz) {
        return PageSpec(
          title: t.whereTitle,
          body: SizedBox(
            width: w,
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
            _actionFor(c, t.back, () => c.go(SetupPage.language), primary: false),
            _actionFor(c, t.continueLabel, () => c.go(SetupPage.options)),
          ],
        );
      }
      // flow/editorial/mini/wizard/fluent: karsilama ve ayarlar tek ekranda —
      // ayri "Ozellestir" adimi yok.
      if (flow || editorial || mini || wizard || fluent) {
        final Widget body;
        if (flow) {
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FolderField(c: c, t: t),
              const SizedBox(height: 6),
              ToggleRow(title: t.optStartMenu, hint: t.optStartMenuHint, value: c.options.startMenu, onChanged: c.toggleStartMenu, showHint: false),
              ToggleRow(title: t.optDesktop, hint: t.optDesktopHint, value: c.options.desktop, onChanged: c.toggleDesktop, showHint: false),
              ToggleRow(title: t.optAutostart, hint: t.optAutostartHint, value: c.options.autostart, onChanged: c.toggleAutostart, showHint: false),
              if (c.sereneRunning) ...[const SizedBox(height: 6), _RunningCard(c: c, t: t)],
              if (missing) ...[
                const SizedBox(height: 6),
                Text('Setup files are missing:\n${c.installer.payloadDir}', style: mono(11, color: Serene.error)),
              ],
            ],
          );
        } else if (editorial) {
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FolderRow(c: c, t: t),
              const _Hair(),
              ToggleRow(title: t.optStartMenu, hint: t.optStartMenuHint, value: c.options.startMenu, onChanged: c.toggleStartMenu, showHint: false),
              const _Hair(),
              ToggleRow(title: t.optDesktop, hint: t.optDesktopHint, value: c.options.desktop, onChanged: c.toggleDesktop, showHint: false),
              const _Hair(),
              ToggleRow(title: t.optAutostart, hint: t.optAutostartHint, value: c.options.autostart, onChanged: c.toggleAutostart, showHint: false),
              const _Hair(),
              if (c.sereneRunning) ...[const SizedBox(height: 12), _RunningLine(c: c, t: t)],
              if (missing) ...[
                const SizedBox(height: 8),
                Text('Setup files are missing:\n${c.installer.payloadDir}', style: mono(11, color: Serene.error)),
              ],
            ],
          );
        } else if (mini) {
          body = _MiniWelcome(c: c, t: t, missing: missing);
        } else if (wizard) {
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FolderField(c: c, t: t),
              const SizedBox(height: 6),
              ToggleRow(title: t.optStartMenu, hint: t.optStartMenuHint, value: c.options.startMenu, onChanged: c.toggleStartMenu),
              ToggleRow(title: t.optDesktop, hint: t.optDesktopHint, value: c.options.desktop, onChanged: c.toggleDesktop),
              ToggleRow(title: t.optAutostart, hint: t.optAutostartHint, value: c.options.autostart, onChanged: c.toggleAutostart),
              if (c.sereneRunning) ...[const SizedBox(height: 6), _RunningCard(c: c, t: t)],
              if (missing) ...[
                const SizedBox(height: 6),
                Text('Setup files are missing:\n${c.installer.payloadDir}', style: mono(11, color: Serene.error)),
              ],
            ],
          );
        } else {
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FluentFolderField(c: c, t: t),
              const SizedBox(height: 12),
              _FluentCheckRow(title: t.optStartMenu, value: c.options.startMenu, onChanged: c.toggleStartMenu),
              _FluentCheckRow(title: t.optDesktop, value: c.options.desktop, onChanged: c.toggleDesktop),
              _FluentCheckRow(title: t.optAutostart, value: c.options.autostart, onChanged: c.toggleAutostart),
              if (c.sereneRunning) ...[const SizedBox(height: 10), _RunningCard(c: c, t: t)],
              if (missing) ...[
                const SizedBox(height: 6),
                Text('Setup files are missing:\n${c.installer.payloadDir}', style: mono(11, color: Serene.error)),
              ],
            ],
          );
        }
        return PageSpec(
          title: t.welcomeTitle,
          subtitle: t.welcomeBody,
          leading: editorial ? Text('${t.version} ${c.args.version}', style: mono(11)) : null,
          body: SizedBox(width: w, child: body),
          actions: [
            if (wizard) _actionFor(c, t.back, () => c.go(SetupPage.language), primary: false),
            _actionFor(c, t.install, c.sereneRunning || missing ? null : c.startInstall),
          ],
        );
      }
      return PageSpec(
        title: t.welcomeTitle,
        subtitle: t.welcomeBody,
        leading: calm ? null : Text('${t.version} ${c.args.version}', style: mono(11)),
        body: SizedBox(
          width: w,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (c.sereneRunning) _RunningCard(c: c, t: t),
              if (missing) Text('Setup files are missing:\n${c.installer.payloadDir}', style: mono(11, color: Serene.error)),
            ],
          ),
        ),
        actions: [
          _actionFor(c, t.customize, c.sereneRunning || missing ? null : () => c.go(SetupPage.options), primary: false),
          _actionFor(c, t.install, c.sereneRunning || missing ? null : c.startInstall),
        ],
      );

    case SetupPage.options:
      return PageSpec(
        title: t.optionsTitle,
        body: SizedBox(
          width: w,
          child: quiz
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _CheckRow(title: t.optStartMenu, hint: t.optStartMenuHint, value: c.options.startMenu, onChanged: c.toggleStartMenu),
                    _CheckRow(title: t.optDesktop, hint: t.optDesktopHint, value: c.options.desktop, onChanged: c.toggleDesktop),
                    _CheckRow(title: t.optAutostart, hint: t.optAutostartHint, value: c.options.autostart, onChanged: c.toggleAutostart),
                    if (c.sereneRunning) ...[const SizedBox(height: 14), _RunningCard(c: c, t: t)],
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _FolderField(c: c, t: t),
                    const SizedBox(height: 6),
                    ToggleRow(title: t.optStartMenu, hint: t.optStartMenuHint, value: c.options.startMenu, onChanged: c.toggleStartMenu, showHint: !calm),
                    ToggleRow(title: t.optDesktop, hint: t.optDesktopHint, value: c.options.desktop, onChanged: c.toggleDesktop, showHint: !calm),
                    ToggleRow(title: t.optAutostart, hint: t.optAutostartHint, value: c.options.autostart, onChanged: c.toggleAutostart, showHint: !calm),
                    if (c.sereneRunning) ...[const SizedBox(height: 6), _RunningCard(c: c, t: t)],
                  ],
                ),
        ),
        actions: [
          _actionFor(c, t.back, () => c.go(SetupPage.welcome), primary: false),
          _actionFor(c, t.install, c.sereneRunning ? null : c.startInstall),
        ],
      );

    case SetupPage.installing:
      return PageSpec(title: t.installingTitle, body: _progressBody(c, t, w));

    case SetupPage.removing:
      return PageSpec(title: t.removingTitle, body: _progressBody(c, t, w));

    case SetupPage.done:
      if (quiz) {
        return PageSpec(
          title: t.doneTitle,
          subtitle: t.doneBody,
          actions: [
            _QuizBack(label: t.finish, showArrow: false, onTap: () => c.finishWith(false)),
            _actionFor(c, t.launchSerene, () => c.finishWith(true)),
          ],
          body: const SizedBox.shrink(),
        );
      }
      return PageSpec(
        title: t.doneTitle,
        subtitle: t.doneBody,
        actions: [_actionFor(c, t.finish, c.finish)],
        body: SizedBox(
          width: w,
          child: Column(
            crossAxisAlignment: calm || flow ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              const AnimatedCheck(size: 46),
              const SizedBox(height: 8),
              if (fluent)
                _FluentCheckRow(title: t.launchSerene, value: c.launchAfter, onChanged: c.toggleLaunch)
              else
                ToggleRow(title: t.launchSerene, hint: '', value: c.launchAfter, onChanged: c.toggleLaunch, showHint: false),
            ],
          ),
        ),
      );

    case SetupPage.error:
      final message = c.error == 'notInstalled' ? t.notInstalled : (c.error ?? '');
      return PageSpec(
        title: t.errorTitle,
        actions: [
          _actionFor(c, t.close, () => exit(0), primary: false),
          if (c.error != 'notInstalled')
            _actionFor(c, t.retry, c.args.uninstall ? c.startUninstall : () => c.go(SetupPage.welcome)),
        ],
        body: Container(
          width: w,
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
          _actionFor(c, t.cancel, () => exit(0), primary: false),
          _actionFor(c, t.uninstall, c.sereneRunning ? null : c.startUninstall, danger: true),
        ],
        body: SizedBox(
          width: w,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              quiz
                  ? _CheckRow(title: t.keepData, hint: t.keepDataHint, value: c.keepData, onChanged: c.toggleKeepData)
                  : fluent
                      ? _FluentCheckRow(title: t.keepData, value: c.keepData, onChanged: c.toggleKeepData)
                      : ToggleRow(title: t.keepData, hint: t.keepDataHint, value: c.keepData, onChanged: c.toggleKeepData, showHint: !calm && !editorial),
              if (editorial) const _Hair(),
              if (c.sereneRunning) ...[
                const SizedBox(height: 10),
                editorial ? _RunningLine(c: c, t: t) : _RunningCard(c: c, t: t),
              ],
            ],
          ),
        ),
      );

    case SetupPage.removed:
      return PageSpec(
        title: t.removedTitle,
        subtitle: t.removedBody,
        actions: [_actionFor(c, t.finish, c.finish)],
        body: quiz ? const SizedBox.shrink() : const AnimatedCheck(size: 46),
      );
  }
}

Widget _progressBody(SetupController c, L t, double width) {
  final percent = (c.progress * 100).round();
  if (c.variant == SetupVariant.quiz) {
    // Quiz: yuzde buyuk serif sayi olarak one cikar.
    return SizedBox(
      width: width,
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
  final fluent = c.variant == SetupVariant.fluent;
  final Widget bar;
  if (c.variant == SetupVariant.editorial) {
    bar = _HairProgress(value: c.progress);
  } else if (fluent) {
    bar = _FluentProgress(value: c.progress);
  } else {
    bar = SoftProgress(value: c.progress);
  }
  return SizedBox(
    width: width,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Align(
                  key: ValueKey(c.step),
                  alignment: Alignment.centerLeft,
                  child: Text(_stepLabel(t, c.step), style: fluent ? seg(13, weight: FontWeight.w600) : body(13, weight: FontWeight.w600)),
                ),
              ),
            ),
            Text('$percent%', style: fluent ? seg(12, weight: FontWeight.w600, color: Serene.primary) : mono(11.5, color: Serene.primary)),
          ],
        ),
        const SizedBox(height: 10),
        bar,
        const SizedBox(height: 10),
        SizedBox(height: 16, child: Text(c.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(10.5))),
      ],
    ),
  );
}
