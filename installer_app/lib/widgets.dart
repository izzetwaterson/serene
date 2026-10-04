import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Hafif giris animasyonu: yukaridan hafifce kayarak belirir.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({super.key, required this.child, this.delayMs = 0, this.dy = 14});

  final Widget child;
  final int delayMs;
  final double dy;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    if (widget.delayMs == 0) {
      _c.forward();
    } else {
      Future<void>.delayed(Duration(milliseconds: widget.delayMs), () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(offset: Offset(0, (1 - _t.value) * widget.dy), child: child),
      ),
      child: widget.child,
    );
  }
}

/// Marka paneli: suzulen yaprak, nefes alan hale ve (istenirse) ilerleme halkasi.
class LeafMark extends StatefulWidget {
  const LeafMark({super.key, this.progress, this.size = 150});

  /// null ise halka cizilmez.
  final double? progress;
  final double size;

  @override
  State<LeafMark> createState() => _LeafMarkState();
}

class _LeafMarkState extends State<LeafMark> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.82, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutBack,
      builder: (context, enter, child) => Opacity(
        opacity: enter.clamp(0.0, 1.0),
        child: Transform.scale(scale: enter, child: child),
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final wave = math.sin(_c.value * 2 * math.pi);
            final breathe = (math.sin(_c.value * 2 * math.pi + math.pi / 2) + 1) / 2;
            return Stack(
              alignment: Alignment.center,
              children: [
                // Nefes alan hale
                Container(
                  width: size * (0.78 + 0.06 * breathe),
                  height: size * (0.78 + 0.06 * breathe),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [
                      Serene.primaryFixedDim.withValues(alpha: 0.34 + 0.16 * breathe),
                      Serene.primaryFixedDim.withValues(alpha: 0),
                    ]),
                  ),
                ),
                if (widget.progress != null)
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: widget.progress!.clamp(0.0, 1.0)),
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, _) => CustomPaint(
                      size: Size.square(size),
                      painter: _RingPainter(value),
                    ),
                  ),
                // Suzulen yaprak
                Transform.translate(
                  offset: Offset(0, wave * 5),
                  child: Transform.rotate(
                    angle: wave * 0.035,
                    child: LeafImage(size: size * 0.7),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Marka yapragi. Koyu temada gamma ile acilmis kopya kullanilir; yoksa
/// koyu zumrut yaprak koyu zeminde kaybolur.
class LeafImage extends StatelessWidget {
  const LeafImage({super.key, required this.size, this.opacity = 1});

  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final dark = Serene.brightness == Brightness.dark;
    return Opacity(
      opacity: opacity,
      child: Image.asset(
        dark ? 'assets/icons/leaf_dark.png' : 'assets/icons/leaf.png',
        width: size,
        height: size,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value);

  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final ring = rect.deflate(4);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = Serene.primaryFixedDim.withValues(alpha: 0.28);
    canvas.drawArc(ring, 0, math.pi * 2, false, track);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = Serene.primary;
    canvas.drawArc(ring, -math.pi / 2, math.pi * 2 * value, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value;
}

/// Dolu (birincil) ve hayalet dugme.
class SButton extends StatefulWidget {
  const SButton({super.key, required this.label, required this.onTap, this.primary = true, this.compact = false});

  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool compact;

  @override
  State<SButton> createState() => _SButtonState();
}

class _SButtonState extends State<SButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final Color bg;
    final Color fg;
    if (widget.primary) {
      bg = enabled ? (_hover ? Serene.primaryHover : Serene.primary) : Serene.outlineVariant;
      fg = enabled ? Serene.onPrimary : Serene.onSurfaceVariant;
    } else {
      bg = _hover && enabled ? Serene.surfaceContainer : Colors.transparent;
      fg = enabled ? Serene.onSurface : Serene.onSurfaceVariant;
    }
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: EdgeInsets.symmetric(horizontal: widget.compact ? 12 : 20, vertical: widget.compact ? 6 : 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: widget.primary ? null : Border.all(color: Serene.outlineVariant),
          ),
          child: Text(widget.label, style: body(widget.compact ? 12 : 13, weight: FontWeight.w700, color: fg)),
        ),
      ),
    );
  }
}

/// Basligi, ipucu metni ve kaydirma dugmesi olan secenek satiri.
class ToggleRow extends StatefulWidget {
  const ToggleRow({super.key, required this.title, required this.hint, required this.value, required this.onChanged, this.showHint = true});

  final String title;
  final String hint;

  /// Minimal yerlesimde ipucu satiri gizlenir.
  final bool showHint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<ToggleRow> createState() => _ToggleRowState();
}

class _ToggleRowState extends State<ToggleRow> {
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
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: widget.showHint ? 6 : 7),
          decoration: BoxDecoration(
            color: _hover ? Serene.surfaceContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title, style: body(13, weight: FontWeight.w600)),
                    if (widget.showHint && widget.hint.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(widget.hint, style: body(11.5, color: Serene.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _Switch(value: widget.value),
            ],
          ),
        ),
      ),
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch({required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: 34,
      height: 20,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: value ? Serene.primary : Serene.outlineVariant,
        borderRadius: BorderRadius.circular(10),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: value ? Serene.onPrimary : Serene.surfaceLowest,
            shape: BoxShape.circle,
            boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 3, offset: Offset(0, 1))],
          ),
        ),
      ),
    );
  }
}

/// Basari isareti: daire belirir, tik cizilir.
class AnimatedCheck extends StatelessWidget {
  const AnimatedCheck({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => CustomPaint(size: Size.square(size), painter: _CheckPainter(t)),
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final circleT = Curves.easeOutBack.transform((t / 0.5).clamp(0.0, 1.0));
    final center = size.center(Offset.zero);
    canvas.drawCircle(center, size.width / 2 * circleT, Paint()..color = Serene.primaryFixed);

    final checkT = ((t - 0.4) / 0.6).clamp(0.0, 1.0);
    if (checkT <= 0) return;
    final w = size.width;
    final path = Path()
      ..moveTo(w * 0.29, w * 0.52)
      ..lineTo(w * 0.44, w * 0.66)
      ..lineTo(w * 0.72, w * 0.36);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * Curves.easeOut.transform(checkT)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.075
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = Serene.primary,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.t != t;
}

/// Ince, yumusak dolan ilerleme cubugu.
class SoftProgress extends StatelessWidget {
  const SoftProgress({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
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
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [Serene.primaryFixedDim, Serene.primary]),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pencere sag ustundeki kapat dugmesi.
class CloseDot extends StatefulWidget {
  const CloseDot({super.key, required this.onTap});

  final VoidCallback? onTap;

  @override
  State<CloseDot> createState() => _CloseDotState();
}

class _CloseDotState extends State<CloseDot> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: _hover && enabled ? Serene.surfaceContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.close_rounded, size: 16, color: enabled ? Serene.onSurfaceVariant : Serene.outlineVariant),
        ),
      ),
    );
  }
}

/// Dil secim karti: buyuk monogram + ana dildeki ad.
class LangCard extends StatefulWidget {
  const LangCard({super.key, required this.code, required this.name, required this.selected, required this.onTap});

  final String code;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<LangCard> createState() => _LangCardState();
}

class _LangCardState extends State<LangCard> {
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
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: sel ? Serene.tintPrimary : (_hover ? Serene.surfaceContainer : Colors.transparent),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: sel ? Serene.primary : Serene.outlineVariant, width: sel ? 1.5 : 1),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: sel ? Serene.primary : Serene.primaryFixed,
                ),
                child: Text(
                  widget.code,
                  style: body(11.5, weight: FontWeight.w700, color: sel ? Serene.onPrimary : Serene.primary),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(widget.name, style: head(17, weight: FontWeight.w500))),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: sel ? 1 : 0,
                child: Icon(Icons.check_circle_rounded, color: Serene.primary, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
