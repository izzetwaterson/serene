import 'package:flutter/material.dart';

import 'format.dart';
import 'theme.dart';

/// Yuvarlak ikon dugmesi; hover'da ton degistirir (kart aksiyonlari).
class CircleButton extends StatefulWidget {
  const CircleButton({
    super.key,
    required this.icon,
    required this.title,
    required this.background,
    required this.foreground,
    required this.hoverBackground,
    this.size = 36,
    this.iconSize = 18,
    this.border,
    this.onTap,
  });

  final String icon;
  final String title;
  final Color background;
  final Color foreground;
  final Color hoverBackground;
  final double size;
  final double iconSize;
  final Color? border;
  final VoidCallback? onTap;

  @override
  State<CircleButton> createState() => _CircleButtonState();
}

class _CircleButtonState extends State<CircleButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.title,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: _hover ? widget.hoverBackground : widget.background,
              shape: BoxShape.circle,
              border: widget.border == null
                  ? null
                  : Border.all(color: widget.border!),
            ),
            child: Center(
              child: SIcon(
                widget.icon,
                size: widget.iconSize,
                color: widget.foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Iki ton arasinda yumusak gecis yapan dikdortgen yuzey (nav satirlari, kartlar).
class HoverSurface extends StatefulWidget {
  const HoverSurface({
    super.key,
    required this.child,
    required this.background,
    this.hoverBackground,
    this.radius = Serene.radiusTile,
    this.padding = EdgeInsets.zero,
    this.onTap,
    this.border,
    this.cursor = SystemMouseCursors.click,
  });

  final Widget child;
  final Color background;
  final Color? hoverBackground;
  final double radius;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final BoxBorder? border;
  final MouseCursor cursor;

  @override
  State<HoverSurface> createState() => _HoverSurfaceState();
}

class _HoverSurfaceState extends State<HoverSurface> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap == null ? MouseCursor.defer : widget.cursor,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: _hover && widget.hoverBackground != null
                ? widget.hoverBackground
                : widget.background,
            borderRadius: BorderRadius.circular(widget.radius),
            border: widget.border,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Durum rozeti (statusChip).
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: body(10, weight: FontWeight.w600, color: foreground),
      ),
    );
  }
}

/// Bolum basligi: solda Fraunces baslik, sagda rozet ve/veya aksiyon.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.badge,
    this.action,
    this.pulse = false,
    this.trailing,
  });

  final String title;
  final String? badge;
  final Widget? action;
  final bool pulse;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final right = <Widget>[
      if (badge != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Serene.surfaceContainer,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(badge!, style: mono(12, color: Serene.secondary)),
        ),
      ?trailing,
      ?action,
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          if (pulse) ...[_PulseDot(), const SizedBox(width: 8)],
          Text(
            title,
            style: head(20, color: Serene.onBackground, letterSpacing: -0.2),
          ),
          const Spacer(),
          if (right.isNotEmpty)
            Row(
              children: [
                for (var i = 0; i < right.length; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  right[i],
                ],
              ],
            ),
        ],
      ),
    );
  }
}

/// Canli indirmeyi belli eden nabiz noktasi.
class _PulseDot extends StatefulWidget {
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.35).animate(_controller),
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: Serene.primary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Bos durum kutusu (emptyState).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.hint,
  });

  final String icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 56),
      decoration: BoxDecoration(
        color: Serene.surfaceContainerLow.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Serene.radiusCard),
        border: Border.all(color: Serene.outlineVariant),
      ),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Serene.surfaceContainer,
              shape: BoxShape.circle,
            ),
            child: Center(child: SIcon(icon, size: 26, color: Serene.outline)),
          ),
          const SizedBox(height: 16),
          Text(title, style: head(18, color: Serene.onBackground)),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 384),
            child: Text(
              hint,
              textAlign: TextAlign.center,
              style: body(13, color: Serene.secondary, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// Etiket + alan: buyuk harfli baslik satiri ve altindaki girdi.
class Field extends StatelessWidget {
  const Field({super.key, required this.label, required this.child});

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
            style: body(
              12,
              weight: FontWeight.w600,
              color: Serene.outline,
              letterSpacing: 0.6,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Okunabilir ama duzenlenemez alan (yol ve baglanti satirlari).
class ReadOnlyField extends StatelessWidget {
  const ReadOnlyField({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: Serene.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Serene.radiusField),
        border: Border.all(color: Serene.borderInput),
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

/// Kart ust bilgisi: kategori ikonu + dosya adi + rozet + meta satiri.
class CardHeader extends StatelessWidget {
  const CardHeader({
    super.key,
    required this.style,
    required this.name,
    required this.meta,
    this.chip,
    this.iconBox = 48,
    this.iconSize = 24,
    this.radius = 16,
    this.nameSize = 16,
    this.nameWeight = FontWeight.w600,
    this.metaSize = 12,
    this.title,
  });

  final CategoryStyle style;
  final String name;
  final String meta;
  final Widget? chip;
  final double iconBox;
  final double iconSize;
  final double radius;
  final double nameSize;
  final FontWeight nameWeight;
  final double metaSize;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: iconBox,
          height: iconBox,
          decoration: BoxDecoration(
            color: style.box,
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Center(
            child: SIcon(style.icon, size: iconSize, color: style.tone),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: body(nameSize, weight: nameWeight),
                    ),
                  ),
                  if (chip != null) ...[const SizedBox(width: 8), chip!],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono(metaSize, color: Serene.secondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Yuvarlak ilerleme bari: track + dolu kisim.
///
/// Hem gorev kartindaki tek toplam bar hem ayri indirme penceresindeki parca
/// basina barlar ayni sekli kullanir; `height` ile pencere biraz daha kalin
/// cizebilir.
class ProgressBar extends StatelessWidget {
  const ProgressBar({
    super.key,
    required this.ratio,
    required this.tone,
    this.height = 8,
  });

  /// 0..1 arasi doluluk; disindaki degerler kirpilir.
  final double ratio;
  final Color tone;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: Serene.surfaceContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: ratio.clamp(0, 1),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              decoration: BoxDecoration(
                color: tone,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
