import 'package:flutter/material.dart';

import 'strings.dart';
import 'theme.dart';

/// Aktif tema modu. Ayarlar katmani yazar, pencere kokleri dinler.
///
/// Varsayilan aydinliktir: uygulama acildigi anda karanlik bir pencere
/// kullaniciyi yamirtir, aydinlik her zaman guvenli bir baslangictir.
final ValueNotifier<ThemeMode> appThemeMode = ValueNotifier(ThemeMode.light);

/// Sistemin bildirdigi parlaklik; pencere acilmadan once de okunabilir.
Brightness systemBrightness() => WidgetsBinding.instance.platformDispatcher.platformBrightness;

/// Motorun ayar dizesini moda cevirir (`system`, `light`, `dark`).
///
/// Taninmayan deger `light`'a duser; eski ayar dosyalari alani hic yazmaz.
ThemeMode themeModeFrom(String raw) => switch (raw.trim().toLowerCase()) {
      'system' => ThemeMode.system,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.light,
    };

/// Modun ayar dizesi karsiligi; motora bu yazilir.
String themeModeSetting(ThemeMode mode) => switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };

String themeModeTitle(ThemeMode mode) => switch (mode) {
      ThemeMode.light => T.themeLight,
      ThemeMode.dark => T.themeDark,
      ThemeMode.system => T.themeSystem,
    };

/// Modu uygular: once palet hazir olur, sonra kokler yeniden kurulur.
/// Palet global oldugu icin sira onemlidir; agac ancak `activate`'dan sonra
/// cizilirse yeni renkleri gorur.
void applyThemeMode(ThemeMode mode) {
  Serene.activate(switch (mode) {
    ThemeMode.light => Brightness.light,
    ThemeMode.dark => Brightness.dark,
    ThemeMode.system => systemBrightness(),
  });
  appThemeMode.value = mode;
}

/// Motorun ayar dizesini uygular.
void applyThemeSetting(String raw) => applyThemeMode(themeModeFrom(raw));
