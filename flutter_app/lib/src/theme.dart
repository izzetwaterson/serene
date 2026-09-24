import 'package:flutter/material.dart';

import 'serene_icons.dart';

/// Serene renk paleti. Degerler src/tailwind.config.js ile birebir aynidir.
class Serene {
  const Serene._();

  static const background = Color(0xFFF7F4ED);
  static const onBackground = Color(0xFF2A2E2B);
  static const onSurface = Color(0xFF2E3230);
  static const surfaceDim = Color(0xFFDBD7CF);
  static const surfaceVariant = Color(0xFFE9E4DB);
  static const surfaceBright = Color(0xFFFAF7F2);
  static const surfaceContainerLowest = Color(0xFFFFFFFF);
  static const surfaceContainerLow = Color(0xFFFAF7F1);
  static const surfaceContainer = Color(0xFFF2EEE6);
  static const surfaceContainerHigh = Color(0xFFEBE5DC);
  static const surfaceContainerHighest = Color(0xFFE2DED5);
  static const onSurfaceVariant = Color(0xFF5F6660);
  static const outline = Color(0xFF8A9088);
  static const outlineVariant = Color(0xFFDCD8CE);

  static const primary = Color(0xFF3D6A4B);
  static const onPrimary = Color(0xFFFFFFFF);
  static const primaryContainer = Color(0xFF4A7C59);
  static const primaryFixed = Color(0xFFD3EBD8);
  static const primaryFixedDim = Color(0xFF8ECF9E);
  static const onPrimaryFixed = Color(0xFF002110);

  static const secondary = Color(0xFF6B6358);
  static const onSecondary = Color(0xFFFFFFFF);
  static const secondaryContainer = Color(0xFFF0E8DB);
  static const onSecondaryContainer = Color(0xFF5E5548);
  static const secondaryFixedDim = Color(0xFFD4CCBF);

  static const tertiary = Color(0xFFA86B32);
  static const tertiaryContainer = Color(0xFFEEDFCC);
  static const tertiaryFixed = Color(0xFFF8E0A8);
  static const onTertiaryFixed = Color(0xFF221A05);
  static const onTertiaryContainer = Color(0xFF554020);

  static const error = Color(0xFFB83230);
  static const errorContainer = Color(0xFFFCE4E2);
  static const onErrorContainer = Color(0xFF7A1A18);

  static const fontHeadline = 'Fraunces';
  static const fontBody = 'Nunito Sans';
  static const fontMono = 'JetBrains Mono';

  static const double radiusCard = 24;
  static const double radiusTile = 16;
  static const double radiusField = 12;

  /// tailwind boxShadow.soft
  static const shadowSoft = <BoxShadow>[
    BoxShadow(color: Color(0x0A3C342A), blurRadius: 14, spreadRadius: -2, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x083C342A), blurRadius: 3, offset: Offset(0, 1)),
  ];

  /// tailwind boxShadow.float
  static const shadowFloat = <BoxShadow>[
    BoxShadow(color: Color(0x1232281E), blurRadius: 30, spreadRadius: -6, offset: Offset(0, 10)),
    BoxShadow(color: Color(0x0A32281E), blurRadius: 8, spreadRadius: -2, offset: Offset(0, 2)),
  ];
}

/// Basliklar icin Fraunces.
TextStyle head(
  double size, {
  FontWeight weight = FontWeight.w400,
  Color color = Serene.onBackground,
  double? letterSpacing,
  double? height,
}) =>
    TextStyle(
      fontFamily: Serene.fontHeadline,
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
    );

/// Govde metni icin Nunito Sans.
TextStyle body(
  double size, {
  FontWeight weight = FontWeight.w400,
  Color color = Serene.onSurface,
  double? height,
  double? letterSpacing,
}) =>
    TextStyle(
      fontFamily: Serene.fontBody,
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );

/// Sayilar ve yollar icin JetBrains Mono.
TextStyle mono(
  double size, {
  FontWeight weight = FontWeight.w400,
  Color color = Serene.onSurface,
  double? height,
}) =>
    TextStyle(
      fontFamily: Serene.fontMono,
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
    );

/// Material Symbols ikonu.
///
/// Web arayuzu ligatur adiyla ciziyor ("spa"), ancak Flutter tarafinda
/// yazi typeini PUA kod noktasiyla cagirmak daha saglam: kullanilmayan
/// harf glifleri atildigi icin ligature tablosu yok ve sekillendirme
/// ozelligine bagimli kaliniyor. Bilinmeyen ad 'draft'a duser.
class SIcon extends StatelessWidget {
  const SIcon(this.name, {super.key, this.size = 18, this.color = Serene.onSurface});

  final String name;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Icon(kSereneIcons[name] ?? kSereneIcons['draft']!, size: size, color: color);
  }
}

/// Yazi tipini test etmek icin basit tema.
ThemeData sereneTheme() {
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: Serene.background,
    fontFamily: Serene.fontBody,
    splashFactory: NoSplash.splashFactory,
    colorScheme: const ColorScheme.light(
      primary: Serene.primary,
      onPrimary: Serene.onPrimary,
      surface: Serene.surfaceContainerLow,
      onSurface: Serene.onSurface,
      error: Serene.error,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Serene.primary,
      selectionColor: Serene.primaryFixed,
    ),
  );
}
