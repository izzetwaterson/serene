import 'package:flutter/material.dart';

import 'serene_icons.dart';

/// Tek bir temanin butun renkleri.
class _Palette {
  const _Palette({
    required this.background,
    required this.onBackground,
    required this.onSurface,
    required this.surfaceDim,
    required this.surfaceVariant,
    required this.surfaceBright,
    required this.surfaceContainerLowest,
    required this.surfaceContainerLow,
    required this.surfaceContainer,
    required this.surfaceContainerHigh,
    required this.surfaceContainerHighest,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.primaryFixed,
    required this.primaryFixedDim,
    required this.onPrimaryFixed,
    required this.secondary,
    required this.onSecondary,
    required this.secondaryContainer,
    required this.onSecondaryContainer,
    required this.secondaryFixedDim,
    required this.tertiary,
    required this.tertiaryContainer,
    required this.tertiaryFixed,
    required this.onTertiaryFixed,
    required this.onTertiaryContainer,
    required this.error,
    required this.errorContainer,
    required this.onErrorContainer,
    required this.primaryHover,
    required this.primaryHoverStrong,
    required this.borderSoft,
    required this.borderInput,
    required this.borderFaint,
    required this.borderPrimary,
    required this.tintPrimary,
    required this.tintPrimaryStrong,
    required this.tintTertiary,
    required this.tintTertiaryStrong,
    required this.tintError,
    required this.shadowSoft,
    required this.shadowFloat,
  });

  final Color background;
  final Color onBackground;
  final Color onSurface;
  final Color surfaceDim;
  final Color surfaceVariant;
  final Color surfaceBright;
  final Color surfaceContainerLowest;
  final Color surfaceContainerLow;
  final Color surfaceContainer;
  final Color surfaceContainerHigh;
  final Color surfaceContainerHighest;
  final Color onSurfaceVariant;
  final Color outline;
  final Color outlineVariant;

  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color primaryFixed;
  final Color primaryFixedDim;
  final Color onPrimaryFixed;

  final Color secondary;
  final Color onSecondary;
  final Color secondaryContainer;
  final Color onSecondaryContainer;
  final Color secondaryFixedDim;

  final Color tertiary;
  final Color tertiaryContainer;
  final Color tertiaryFixed;
  final Color onTertiaryFixed;
  final Color onTertiaryContainer;

  final Color error;
  final Color errorContainer;
  final Color onErrorContainer;

  /// Dolu yesil yuzeylerin uzerine gelince gorunen ton.
  final Color primaryHover;
  final Color primaryHoverStrong;

  /// `outlineVariant`in yuzde 50 / 60 / 40 saydamlikli kisayollari.
  final Color borderSoft;
  final Color borderInput;
  final Color borderFaint;

  /// Avatar halkasi gibi yerlerde birincil rengin saydam hali.
  final Color borderPrimary;

  /// Ikon kutusu ve rozet zeminleri.
  final Color tintPrimary;
  final Color tintPrimaryStrong;
  final Color tintTertiary;
  final Color tintTertiaryStrong;
  final Color tintError;

  final List<BoxShadow> shadowSoft;
  final List<BoxShadow> shadowFloat;
}

/// Aydinlik palet. Degerler src/tailwind.config.js ile birebir aynidir.
const _light = _Palette(
  background: Color(0xFFF7F4ED),
  onBackground: Color(0xFF2A2E2B),
  onSurface: Color(0xFF2E3230),
  surfaceDim: Color(0xFFDBD7CF),
  surfaceVariant: Color(0xFFE9E4DB),
  surfaceBright: Color(0xFFFAF7F2),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFFAF7F1),
  surfaceContainer: Color(0xFFF2EEE6),
  surfaceContainerHigh: Color(0xFFEBE5DC),
  surfaceContainerHighest: Color(0xFFE2DED5),
  onSurfaceVariant: Color(0xFF5F6660),
  outline: Color(0xFF8A9088),
  outlineVariant: Color(0xFFDCD8CE),
  primary: Color(0xFF3D6A4B),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFF4A7C59),
  primaryFixed: Color(0xFFD3EBD8),
  primaryFixedDim: Color(0xFF8ECF9E),
  onPrimaryFixed: Color(0xFF002110),
  secondary: Color(0xFF6B6358),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFF0E8DB),
  onSecondaryContainer: Color(0xFF5E5548),
  secondaryFixedDim: Color(0xFFD4CCBF),
  tertiary: Color(0xFFA86B32),
  tertiaryContainer: Color(0xFFEEDFCC),
  tertiaryFixed: Color(0xFFF8E0A8),
  onTertiaryFixed: Color(0xFF221A05),
  onTertiaryContainer: Color(0xFF554020),
  error: Color(0xFFB83230),
  errorContainer: Color(0xFFFCE4E2),
  onErrorContainer: Color(0xFF7A1A18),
  primaryHover: Color(0xE63D6A4B),
  primaryHoverStrong: Color(0xF23D6A4B),
  borderSoft: Color(0x80DCD8CE),
  borderInput: Color(0x99DCD8CE),
  borderFaint: Color(0x66DCD8CE),
  borderPrimary: Color(0x333D6A4B),
  tintPrimary: Color(0x66D3EBD8),
  tintPrimaryStrong: Color(0x80D3EBD8),
  tintTertiary: Color(0x66F8E0A8),
  tintTertiaryStrong: Color(0x80F8E0A8),
  tintError: Color(0xB3FCE4E2),
  shadowSoft: <BoxShadow>[
    BoxShadow(color: Color(0x0A3C342A), blurRadius: 14, spreadRadius: -2, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x083C342A), blurRadius: 3, offset: Offset(0, 1)),
  ],
  shadowFloat: <BoxShadow>[
    BoxShadow(color: Color(0x1232281E), blurRadius: 30, spreadRadius: -6, offset: Offset(0, 10)),
    BoxShadow(color: Color(0x0A32281E), blurRadius: 8, spreadRadius: -2, offset: Offset(0, 2)),
  ],
);

/// Karanlik palet: ayni sicak kagit dili, gece icin cozulmus tonlarla.
///
/// Dolu yesil yuzeyler burada acik tona gecer ve uzerlerine koyu metin gelir;
/// boylece "yesil dugme" kimligi korunurken beyaz metnin kontrasti da
/// 4.5:1 esiginin altina dusmez.
const _dark = _Palette(
  background: Color(0xFF161815),
  onBackground: Color(0xFFE8E7DE),
  onSurface: Color(0xFFE5E4DB),
  surfaceDim: Color(0xFF101110),
  surfaceVariant: Color(0xFF2E312B),
  surfaceBright: Color(0xFF474A41),
  surfaceContainerLowest: Color(0xFF1D1F1B),
  surfaceContainerLow: Color(0xFF212420),
  surfaceContainer: Color(0xFF272A25),
  surfaceContainerHigh: Color(0xFF31342E),
  surfaceContainerHighest: Color(0xFF3B3E36),
  onSurfaceVariant: Color(0xFFB7BBB0),
  outline: Color(0xFF8E9389),
  outlineVariant: Color(0xFF3F433B),
  // Koyu modda yesil, aydinlik moddakinden **koyu ve daha az parlak**:
  // primary #5A8F68. Onceki deger #9BD3AC idi ve kontrasti 10.47 cikiyordu;
  // bu kadar parlak bir dolgu gece modunda goz yoruyor.
  primary: Color(0xFF5A8F68),
  // Dolgu orta parlaklikta kaldigi icin uzerindeki yazi **koyu** olmali; beyaz
  // yazi bu dolguda yalnizca 3.77 kontrast veriyor (WCAG AA esigi 4.5),
  // koyu yazi ise 4.52 veriyor. Aydinlik modun tersi: orada dolgu koyu,
  // yazi beyaz.
  onPrimary: Color(0xFF0B2013),
  // primaryContainer bir *yuzey* rengi (secili sekmenin arka plani gibi), metin
  // rengi degil. Eski #2F5139 kontrasti yalnizca 2.00 idi; hafif acildi.
  primaryContainer: Color(0xFF33543C),
  primaryFixed: Color(0xFF2F4A35),
  primaryFixedDim: Color(0xFF6FA37E),
  onPrimaryFixed: Color(0xFFC9E6D2),
  secondary: Color(0xFFA8A294),
  onSecondary: Color(0xFF1B1D19),
  secondaryContainer: Color(0xFF3A3830),
  onSecondaryContainer: Color(0xFFE2DACB),
  secondaryFixedDim: Color(0xFF4C483E),
  tertiary: Color(0xFFD8A468),
  tertiaryContainer: Color(0xFF43301C),
  tertiaryFixed: Color(0xFF4A3520),
  onTertiaryFixed: Color(0xFFF3D9AE),
  onTertiaryContainer: Color(0xFFEFD7B0),
  error: Color(0xFFE8928E),
  errorContainer: Color(0xFF5A2422),
  onErrorContainer: Color(0xFFF5C9C6),
  // Hover'da dolgu bir kademe acilir; koyu yazi kontrasti 4.52 -> 5.80 olur,
  // yani AA'da kalir (beyaz yazi kullanilsaydi 2.95'e dusuyordu).
  primaryHover: Color(0xFF6BA377),
  primaryHoverStrong: Color(0xFF7CB785),
  borderSoft: Color(0x803F433B),
  borderInput: Color(0x993F433B),
  borderFaint: Color(0x663F433B),
  borderPrimary: Color(0x4D5A8F68),
  tintPrimary: Color(0xFF2C4233),
  tintPrimaryStrong: Color(0xFF35503D),
  tintTertiary: Color(0xFF3E2D17),
  tintTertiaryStrong: Color(0xFF4A361C),
  tintError: Color(0xFF5A2422),
  shadowSoft: <BoxShadow>[
    BoxShadow(color: Color(0x40000000), blurRadius: 14, spreadRadius: -2, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x26000000), blurRadius: 3, offset: Offset(0, 1)),
  ],
  shadowFloat: <BoxShadow>[
    BoxShadow(color: Color(0x59000000), blurRadius: 30, spreadRadius: -6, offset: Offset(0, 10)),
    BoxShadow(color: Color(0x33000000), blurRadius: 8, spreadRadius: -2, offset: Offset(0, 2)),
  ],
);

/// Serene renk paleti.
///
/// Palet calisma aninda secilir (bkz. app_theme.dart): pencere kokleri modu ve
/// sistem parlakligini izler, degisince once `activate` cagrilir sonra agac
/// yeniden kurulur. Bu yuzden tokenlar `static const` degil getter'dir; sabit
/// ifadelerin icinde kullanilamazlar.
class Serene {
  const Serene._();

  static _Palette _palette = _light;
  static Brightness _brightness = Brightness.light;

  static Brightness get brightness => _brightness;

  static void activate(Brightness value) {
    _brightness = value;
    _palette = value == Brightness.dark ? _dark : _light;
  }

  static Color get background => _palette.background;
  static Color get onBackground => _palette.onBackground;
  static Color get onSurface => _palette.onSurface;
  static Color get surfaceDim => _palette.surfaceDim;
  static Color get surfaceVariant => _palette.surfaceVariant;
  static Color get surfaceBright => _palette.surfaceBright;
  static Color get surfaceContainerLowest => _palette.surfaceContainerLowest;
  static Color get surfaceContainerLow => _palette.surfaceContainerLow;
  static Color get surfaceContainer => _palette.surfaceContainer;
  static Color get surfaceContainerHigh => _palette.surfaceContainerHigh;
  static Color get surfaceContainerHighest => _palette.surfaceContainerHighest;
  static Color get onSurfaceVariant => _palette.onSurfaceVariant;
  static Color get outline => _palette.outline;
  static Color get outlineVariant => _palette.outlineVariant;

  static Color get primary => _palette.primary;
  static Color get onPrimary => _palette.onPrimary;
  static Color get primaryContainer => _palette.primaryContainer;
  static Color get primaryFixed => _palette.primaryFixed;
  static Color get primaryFixedDim => _palette.primaryFixedDim;
  static Color get onPrimaryFixed => _palette.onPrimaryFixed;

  static Color get secondary => _palette.secondary;
  static Color get onSecondary => _palette.onSecondary;
  static Color get secondaryContainer => _palette.secondaryContainer;
  static Color get onSecondaryContainer => _palette.onSecondaryContainer;
  static Color get secondaryFixedDim => _palette.secondaryFixedDim;

  static Color get tertiary => _palette.tertiary;
  static Color get tertiaryContainer => _palette.tertiaryContainer;
  static Color get tertiaryFixed => _palette.tertiaryFixed;
  static Color get onTertiaryFixed => _palette.onTertiaryFixed;
  static Color get onTertiaryContainer => _palette.onTertiaryContainer;

  static Color get error => _palette.error;
  static Color get errorContainer => _palette.errorContainer;
  static Color get onErrorContainer => _palette.onErrorContainer;

  static Color get primaryHover => _palette.primaryHover;
  static Color get primaryHoverStrong => _palette.primaryHoverStrong;
  static Color get borderSoft => _palette.borderSoft;
  static Color get borderInput => _palette.borderInput;
  static Color get borderFaint => _palette.borderFaint;
  static Color get borderPrimary => _palette.borderPrimary;
  static Color get tintPrimary => _palette.tintPrimary;
  static Color get tintPrimaryStrong => _palette.tintPrimaryStrong;
  static Color get tintTertiary => _palette.tintTertiary;
  static Color get tintTertiaryStrong => _palette.tintTertiaryStrong;
  static Color get tintError => _palette.tintError;

  static List<BoxShadow> get shadowSoft => _palette.shadowSoft;
  static List<BoxShadow> get shadowFloat => _palette.shadowFloat;

  static const fontHeadline = 'Fraunces';
  static const fontBody = 'Nunito Sans';
  static const fontMono = 'JetBrains Mono';

  static const double radiusCard = 24;
  static const double radiusTile = 16;
  static const double radiusField = 12;

  /// Kontrol yuzeyleri: kucuk onay kutulari ve klavye kisayolu rozeti.
  ///
  /// Ucuncu kademenin altinda ayri bir basamak gerekli: 14 px'lik bir kutuda
  /// 12 px yaricap kutunun yarisini asar ve kareyi daireye cevirirdi.
  static const double radiusControl = 4;
}

/// Basliklar icin Fraunces.
TextStyle head(
  double size, {
  FontWeight weight = FontWeight.w400,
  Color? color,
  double? letterSpacing,
  double? height,
}) =>
    TextStyle(
      fontFamily: Serene.fontHeadline,
      fontSize: size,
      fontWeight: weight,
      color: color ?? Serene.onBackground,
      letterSpacing: letterSpacing,
      height: height,
    );

/// Govde metni icin Nunito Sans.
TextStyle body(
  double size, {
  FontWeight weight = FontWeight.w400,
  Color? color,
  double? height,
  double? letterSpacing,
}) =>
    TextStyle(
      fontFamily: Serene.fontBody,
      fontSize: size,
      fontWeight: weight,
      color: color ?? Serene.onSurface,
      height: height,
      letterSpacing: letterSpacing,
    );

/// Sayilar ve yollar icin JetBrains Mono.
TextStyle mono(double size, {FontWeight weight = FontWeight.w400, Color? color, double? height}) =>
    TextStyle(
      fontFamily: Serene.fontMono,
      fontSize: size,
      fontWeight: weight,
      color: color ?? Serene.onSurface,
      height: height,
    );

/// Material Symbols ikonu.
///
/// Web arayuzu ligatur adiyla ciziyor ("spa"), ancak Flutter tarafinda
/// yazi typeini PUA kod noktasiyla cagirmak daha saglam: kullanilmayan
/// harf glifleri atildigi icin ligature tablosu yok ve sekillendirme
/// ozelligine bagimli kaliniyor. Bilinmeyen ad 'draft'a duser.
class SIcon extends StatelessWidget {
  const SIcon(this.name, {super.key, this.size = 18, this.color});

  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Icon(kSereneIcons[name] ?? kSereneIcons['draft']!,
        size: size, color: color ?? Serene.onSurface);
  }
}

/// Uygulama teması. Iki temayi da acikca uretir; Material bilesenleri
/// (onay kutusu, secim tutamaci) renklerini buradan alir.
ThemeData sereneTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final palette = dark ? _dark : _light;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: palette.background,
    fontFamily: Serene.fontBody,
    splashFactory: NoSplash.splashFactory,
    colorScheme: dark
        ? ColorScheme.dark(
            primary: palette.primary,
            onPrimary: palette.onPrimary,
            surface: palette.surfaceContainerLow,
            onSurface: palette.onSurface,
            error: palette.error,
          )
        : ColorScheme.light(
            primary: palette.primary,
            onPrimary: palette.onPrimary,
            surface: palette.surfaceContainerLow,
            onSurface: palette.onSurface,
            error: palette.error,
          ),
    textSelectionTheme:
        TextSelectionThemeData(cursorColor: palette.primary, selectionColor: palette.primaryFixed),
  );
}
