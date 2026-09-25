import 'package:flutter/material.dart';

import 'strings.dart';
import 'theme.dart';

/// Aktif tema modu. Ayarlar katmani yazar, pencere kokleri dinler.
final ValueNotifier<ThemeMode> appThemeMode = ValueNotifier(ThemeMode.system);

/// Sistemin bildirdigi parlaklik; pencere acilmadan once de okunabilir.
Brightness systemBrightness() => WidgetsBinding.instance.platformDispatcher.platformBrightness;

/// Motorun ayar dizesini moda cevirir (`system`, `light`, `dark`).
ThemeMode themeModeFrom(String raw) => switch (raw.trim().toLowerCase()) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
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
