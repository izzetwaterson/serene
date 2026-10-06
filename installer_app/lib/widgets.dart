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

/// Marka yapragi.
class LeafImage extends StatelessWidget {
  const LeafImage({super.key, required this.size, this.opacity = 1});

  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: Image.asset(
        'assets/icons/leaf.png',
        width: size,
        height: size,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

/// Dolu (birincil) ve hayalet dugme.
class SButton extends StatefulWidget {
  const SButton({super.key, required this.label, required this.onTap, this.primary = true, this.compact = false, this.danger = false});

  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool compact;

  /// Yikici eylem (kaldirma): dolgu kirmiziya doner.
  final bool danger;

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
    if (widget.primary && widget.danger) {
      bg = enabled ? (_hover ? Color.lerp(Serene.error, Colors.black, 0.16)! : Serene.error) : Serene.outlineVariant;
      fg = enabled ? Colors.white : Serene.onSurfaceVariant;
    } else if (widget.primary) {
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
