import 'package:flutter/material.dart';

/// Serene paleti. Degerler `flutter_app/lib/src/theme.dart` ile BIREBIR
/// aynidir (tek gercek kaynak orasi); burada yalnizca kurulum penceresinin
/// kullandigi tokenlar kopyalanir. Palet degisirse ikisi birlikte guncellenir.
class _Palette {
  const _Palette({
    required this.background,
    required this.onBackground,
    required this.onSurface,
    required this.surfaceLowest,
    required this.surfaceLow,
    required this.surfaceContainer,
    required this.onSurfaceVariant,
    required this.outlineVariant,
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.primaryFixed,
    required this.primaryFixedDim,
    required this.primaryHover,
    required this.tintPrimary,
    required this.tertiary,
    required this.tintTertiary,
    required this.error,
    required this.errorContainer,
    required this.onErrorContainer,
    required this.shadowFloat,
  });

  final Color background;
  final Color onBackground;
  final Color onSurface;
  final Color surfaceLowest;
  final Color surfaceLow;
  final Color surfaceContainer;
  final Color onSurfaceVariant;
  final Color outlineVariant;
  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color primaryFixed;
  final Color primaryFixedDim;
  final Color primaryHover;
  final Color tintPrimary;
  final Color tertiary;
  final Color tintTertiary;
  final Color error;
  final Color errorContainer;
  final Color onErrorContainer;
  final List<BoxShadow> shadowFloat;
}

const _light = _Palette(
  background: Color(0xFFF7F4ED),
  onBackground: Color(0xFF2A2E2B),
  onSurface: Color(0xFF2E3230),
  surfaceLowest: Color(0xFFFFFFFF),
  surfaceLow: Color(0xFFFAF7F1),
  surfaceContainer: Color(0xFFF2EEE6),
  onSurfaceVariant: Color(0xFF5F6660),
  outlineVariant: Color(0xFFDCD8CE),
  primary: Color(0xFF3D6A4B),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFF4A7C59),
  primaryFixed: Color(0xFFD3EBD8),
  primaryFixedDim: Color(0xFF8ECF9E),
  primaryHover: Color(0xE63D6A4B),
  tintPrimary: Color(0x66D3EBD8),
  tertiary: Color(0xFFA86B32),
  tintTertiary: Color(0x66F8E0A8),
  error: Color(0xFFB83230),
  errorContainer: Color(0xFFFCE4E2),
  onErrorContainer: Color(0xFF7A1A18),
  shadowFloat: <BoxShadow>[
    BoxShadow(color: Color(0x1232281E), blurRadius: 30, spreadRadius: -6, offset: Offset(0, 10)),
    BoxShadow(color: Color(0x0A32281E), blurRadius: 8, spreadRadius: -2, offset: Offset(0, 2)),
  ],
);

/// Kurulum ve kaldirma yalnizca acik paletle calisir; sistem karanlik olsa
/// bile pencere acik kalir. Karanlik palet ve tema izleme kaldirildi.
class Serene {
  const Serene._();

  static const _Palette _p = _light;

  static Color get background => _p.background;
  static Color get onBackground => _p.onBackground;
  static Color get onSurface => _p.onSurface;
  static Color get surfaceLowest => _p.surfaceLowest;
  static Color get surfaceLow => _p.surfaceLow;
  static Color get surfaceContainer => _p.surfaceContainer;
  static Color get onSurfaceVariant => _p.onSurfaceVariant;
  static Color get outlineVariant => _p.outlineVariant;
  static Color get primary => _p.primary;
  static Color get onPrimary => _p.onPrimary;
  static Color get primaryContainer => _p.primaryContainer;
  static Color get primaryFixed => _p.primaryFixed;
  static Color get primaryFixedDim => _p.primaryFixedDim;
  static Color get primaryHover => _p.primaryHover;
  static Color get tintPrimary => _p.tintPrimary;
  static Color get tertiary => _p.tertiary;
  static Color get tintTertiary => _p.tintTertiary;
  static Color get error => _p.error;
  static Color get errorContainer => _p.errorContainer;
  static Color get onErrorContainer => _p.onErrorContainer;
  static List<BoxShadow> get shadowFloat => _p.shadowFloat;

  static const fontHeadline = 'Fraunces';
  static const fontBody = 'Nunito Sans';
  static const fontMono = 'JetBrains Mono';

  static const double radiusTile = 16;
  static const double radiusField = 12;
}

TextStyle head(double size, {FontWeight weight = FontWeight.w400, Color? color, double? height, double? letterSpacing}) =>
    TextStyle(
      fontFamily: Serene.fontHeadline,
      fontSize: size,
      fontWeight: weight,
      color: color ?? Serene.onBackground,
      height: height,
      letterSpacing: letterSpacing,
    );

TextStyle body(double size, {FontWeight weight = FontWeight.w400, Color? color, double? height}) => TextStyle(
      fontFamily: Serene.fontBody,
      fontSize: size,
      fontWeight: weight,
      color: color ?? Serene.onSurface,
      height: height,
    );

TextStyle mono(double size, {Color? color}) => TextStyle(
      fontFamily: Serene.fontMono,
      fontSize: size,
      color: color ?? Serene.onSurfaceVariant,
    );

ThemeData sereneTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: Serene.background,
    fontFamily: Serene.fontBody,
    splashFactory: NoSplash.splashFactory,
    colorScheme: ColorScheme.light(
      primary: Serene.primary,
      onPrimary: Serene.onPrimary,
      surface: Serene.surfaceLow,
      onSurface: Serene.onSurface,
      error: Serene.error,
    ),
  );
}
