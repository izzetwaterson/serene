import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'data.dart';
import 'folder_picker.dart';
import 'handoff.dart' show engineReason;
import 'license_text.dart';
import 'rust/api/commands.dart' as ffi;
import 'rust/api/dto.dart' as engine;
import 'rust/api/lifecycle.dart' as ffi;
import 'strings.dart';
import 'theme.dart';
import 'widgets.dart';

/// Ayarlar katmani: web arayuzundeki `#settings-modal` ile ayni yerlesim.
/// Pencerenin ustune serilen karartma ve kaydirilabilir panel; `Esc` ya da
/// karartmaya tiklama ile kapanir.
class SettingsLayer extends StatelessWidget {
  const SettingsLayer({
    super.key,
    required this.settings,
    required this.onClose,
    required this.onSaved,
    required this.engineVersion,
  });

  final Settings settings;
  final VoidCallback onClose;
  final ValueChanged<Settings> onSaved;

  /// Motor crate surumu; panelin altindaki surum satirinda gosterilir.
  final String engineVersion;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: onClose,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
              child: ColoredBox(
                color: Serene.onSurface.withValues(alpha: 0.25),
              ),
            ),
          ),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 512,
                // Panel icerige gore kisalir (kisa bir sekmede bosluk birakmaz),
                // ama ust sinir pencerenin kendisidir. Once sabit bir yukseklik
                // vardi; sekmeye gecince her ayar icin farkli uzunlukta bir
                // liste olunca ya tasma ya da bosluk birakiyordu.
                maxHeight: height - 32,
              ),
              child: SettingsPanel(
                settings: settings,
                onClose: onClose,
                onSaved: onSaved,
                engineVersion: engineVersion,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Panelin kendisi: taslagi motorun ayarlarindan alir, kaydedince motora yazar.
class SettingsPanel extends StatefulWidget {
  const SettingsPanel({
    super.key,
    required this.settings,
    required this.onClose,
    required this.onSaved,
    required this.engineVersion,
  });

  final Settings settings;
  final VoidCallback onClose;
  final ValueChanged<Settings> onSaved;

  /// Motor crate'inin surumu. Uygulama surumunden ayri gosterilir; ikisi
  /// cogu kez karistirilir.
  final String engineVersion;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  late final TextEditingController _dir = TextEditingController(
    text: widget.settings.downloadDir,
  );
  late final TextEditingController _concurrent = TextEditingController(
    text: '${widget.settings.maxConcurrent}',
  );
  late final TextEditingController _connections = TextEditingController(
    text: '${widget.settings.connections}',
  );

  late bool _clipboard = widget.settings.watchClipboard;
  late bool _tray = widget.settings.closeToTray;
  late bool _confirm = widget.settings.confirmBrowserDownload;
  late bool _autostart = widget.settings.autostart;
  late ThemeMode _theme = themeModeFrom(widget.settings.theme);
  late AppLanguage _language = languageFrom(widget.settings.language);

  String? _status;
  Color _statusColor = Serene.primary;
  bool _busy = false;
  Timer? _closeTimer;

  /// Aktif sekme. Ayarlar tek sayfada yigiliydi ve panele sigmazdi; kullanicinin
  /// istegiyle uc amaca gore bolundu: gorunum, indirme, davranis.
  int _tab = 0;

  @override
  void dispose() {
    // Kaydedilmeden kapanan panel tema ve dil denemesini geri alir: secim
    // yalnizca "Kaydet" ile kalici olur. Mikro gorev, kapanma karesi
    // bittikten sonra paleti ve metinleri eski haline dondurur.
    final savedTheme = themeModeFrom(widget.settings.theme);
    if (savedTheme != _theme) {
      scheduleMicrotask(() => applyThemeMode(savedTheme));
    }
    final savedLanguage = languageFrom(widget.settings.language);
    if (savedLanguage != _language) {
      scheduleMicrotask(() => applyLanguage(savedLanguage));
    }
    _closeTimer?.cancel();
    _dir.dispose();
    _concurrent.dispose();
    _connections.dispose();
    super.dispose();
  }

  /// Secim aninda boyanir; kaydedilmezse kapanista geri alinir.
  void _pickTheme(ThemeMode mode) {
    setState(() => _theme = mode);
    applyThemeMode(mode);
  }

  /// Panel metinleri de secim aninda degisir; kaydedilmezse geri alinir.
  void _pickLanguage(AppLanguage language) {
    setState(() => _language = language);
    applyLanguage(language);
  }

  Future<void> _browse() async {
    final picked = await pickFolder(
      title: T.chooseFolderTitle,
      initialDirectory: _dir.text.trim().isEmpty ? null : _dir.text.trim(),
    );
    if (picked == null || !mounted) return;
    setState(() => _dir.text = picked);
  }

  /// Motorun kabul edeceği payload; bos/gecersiz sayilar mevcut degerden dusurulur.
  engine.AppConfig _payload() => engine.AppConfig(
    downloadDir: _dir.text.trim(),
    maxConcurrent: parseCount(_concurrent.text, widget.settings.maxConcurrent),
    connections: parseCount(_connections.text, widget.settings.connections),
    watchClipboard: _clipboard,
    closeToTray: _tray,
    confirmBrowserDownload: _confirm,
    theme: themeModeSetting(_theme),
    language: languageSetting(_language),
    autostart: _autostart,
    // Panelde gorunmez; kaydetme yolu alani oldugu gibi tasimali ki
    // kullanici ayar kaydedince tanitim kapisi sifirlanmasin.
    extensionOfferDone: widget.settings.extensionOfferDone,
  );

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final saved = await ffi.updateSettings(settings: _payload());
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = T.savedWord;
        _statusColor = Serene.primary;
      });
      widget.onSaved(Settings.fromEngine(saved));
      // Web arayuzu de onay yazi bir an gorunup pencereyi kapiyor.
      _closeTimer = Timer(const Duration(milliseconds: 600), widget.onClose);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = engineReason(error);
        _statusColor = Serene.onErrorContainer;
      });
    }
  }

  Future<void> _clearCompleted() async {
    if (_busy) return;
    try {
      final removed = await ffi.clearCompleted();
      if (!mounted) return;
      setState(() {
        _status = removed > 0
            ? T.recordsDeleted(removed)
            : T.nothingToDelete;
        _statusColor = Serene.secondary;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = engineReason(error);
        _statusColor = Serene.onErrorContainer;
      });
    }
  }

  // --- Sekmeler -------------------------------------------------------------
  // Ayarlar tek sayfada yigiliydi ve panele sigmazdi; kullanicinin istegiyle
  // uc amaca gore bolundu. Ortak alt bant ("Temizle" + Kaydet) degismez.

  /// Genel: dil ve tema. Iki secici de secim aninda uygulanir (Kaydet'e
  /// beklemez) — kullanici dili ya da temayi secmeden goremez.
  Widget _generalTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Field(
          label: T.languageLabel,
          child: _SegmentedPicker<AppLanguage>(
            value: _language,
            values: AppLanguage.values,
            title: languageTitle,
            onChanged: _pickLanguage,
          ),
        ),
        const SizedBox(height: 24),
        Field(
          label: T.appearanceLabel,
          child: _SegmentedPicker<ThemeMode>(
            value: _theme,
            values: ThemeMode.values,
            title: themeModeTitle,
            onChanged: _pickTheme,
          ),
        ),
      ],
    );
  }

  /// Indirmeler: nereye indirilecek ve kac paralel is.
  Widget _downloadsTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Field(
          label: T.folderLabel,
          child: Row(
            children: [
              Expanded(child: ReadOnlyField(text: _dir.text)),
              const SizedBox(width: 8),
              HoverSurface(
                onTap: _browse,
                radius: Serene.radiusField,
                background: Serene.surfaceContainer,
                hoverBackground: Serene.surfaceContainerHigh,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Text(
                  T.browse,
                  style: body(13, weight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Field(
          label: T.concurrentLabel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _NumberField(controller: _concurrent),
              const SizedBox(height: 6),
              Text(
                T.concurrentHint,
                style: body(11, color: Serene.secondary, height: 1.35),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Field(
          label: T.connectionsLabel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _NumberField(controller: _connections),
              const SizedBox(height: 6),
              Text(
                T.connectionsHint,
                style: body(11, color: Serene.secondary, height: 1.35),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Davranis: uygulamanin kendisiyle ilgili anahtarlar.
  Widget _behaviourTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toggle(
          title: T.watchClipboardTitle,
          hint: T.watchClipboardHint,
          value: _clipboard,
          onChanged: (value) => setState(() => _clipboard = value),
        ),
        const SizedBox(height: 16),
        _Toggle(
          title: T.closeToTrayTitle,
          hint: T.closeToTrayHint,
          value: _tray,
          onChanged: (value) => setState(() => _tray = value),
        ),
        const SizedBox(height: 16),
        _Toggle(
          title: T.confirmBrowserTitle,
          hint: T.confirmBrowserHint,
          value: _confirm,
          onChanged: (value) => setState(() => _confirm = value),
        ),
        const SizedBox(height: 16),
        _Toggle(
          title: T.autostartTitle,
          hint: T.autostartHint,
          value: _autostart,
          onChanged: (value) => setState(() => _autostart = value),
        ),
      ],
    );
  }

  /// Hakkinda: uygulama adi, surum, kaynak kodu baglantisi ve lisans metni.
  ///
  /// Lisans `assets/LICENSE.txt` icinden okunur; metin gomuludur, bu yuzden
  /// ayri bir Rust komutu gerekmez. Motor surumu motorun kendi surumudur ve
  /// uygulama surumunden ayri gosterilir (ikisi sik karistirilir).
  ///
  /// Uygulama surumu `late final` ile **bir kez** okunur. `build` icinde
  /// dogrudan cagrilirsa: (a) her yeniden cizimde FFI cagrisi olur,
  /// (b) motorun kurulmadigi cercevelerde (widget testleri) cokmus olur.
  late final String _appVersion = _readAppVersion();

  static String _readAppVersion() {
    try {
      return ffi.appVersion();
    } catch (_) {
      return '-';
    }
  }

  Widget _aboutTab() {
    // Surum `build` icinde okunmaz: FFI her `build`'de cagirmak pahali ve
    // motorun kurulmadigi cercevelerde (birim testleri) cokmus olur.
    // `late final` bir kez okur, sonra onbellekten gelir.
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // Uygulama markasi: tepsi simgesiyle AYNI ana dosyadan uretilir ama
              // 256px'tir. Burada 56 mantiksal px'e ciziliyor (2x DPI'da 112
              // fiziksel); 32px'lik tepsi dosyasi buyutulunce bulanik olurdu.
              Image.asset('assets/icons/serene_logo.png', width: 56, height: 56),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Serene', style: head(20)),
                    const SizedBox(height: 2),
                    Text(
                      T.aboutDescription,
                      style: body(13, color: Serene.secondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _AboutRow(
            label: T.aboutVersion,
            value: _appVersion,
            monoFont: true,
          ),
          const SizedBox(height: 8),
          _AboutRow(
            label: T.aboutEngine,
            value: widget.engineVersion,
            monoFont: true,
          ),
          const SizedBox(height: 20),
          _AboutLink(
            label: T.aboutRepository,
            value: 'github.com/izzetwaterson/serene',
            url: 'https://github.com/izzetwaterson/serene',
          ),
          const SizedBox(height: 20),
          Text(
            T.aboutLicense,
            style: body(12, weight: FontWeight.w600, color: Serene.secondary),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              child: Text(
                kLicenseText,
                style: mono(11, color: Serene.secondary, height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        LogicalKeySet(LogicalKeyboardKey.escape): const _CloseSettings(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _CloseSettings: CallbackAction<_CloseSettings>(
            onInvoke: (_) {
              widget.onClose();
              return null;
            },
          ),
        },
        // Katman acildigunda odak buraya gelir: aksi halde `Esc` arastirma
        // alanindan yukari turlanir ve bu panele hic ulasamaz.
        child: Focus(
          autofocus: true,
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Serene.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(Serene.radiusCard),
                boxShadow: Serene.shadowFloat,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            T.settingsTitle,
                            style: head(20, color: Serene.onBackground),
                          ),
                        ),
                        CircleButton(
                          icon: 'close',
                          title: T.close,
                          size: 32,
                          iconSize: 17,
                          background: Serene.surfaceContainer,
                          hoverBackground: Serene.surfaceContainerHigh,
                          foreground: Serene.secondary,
                          onTap: widget.onClose,
                        ),
                      ],
                    ),
                  ),
                  // Icerik: surum satiri, sonra solda sekme listesi ve sagda o
                  // sekmenin ayarlari.
                  //
                  // Burada `Flexible` YOK: dis `Column` `mainAxisSize.min`
                  // oldugu icin zaten icerige gore kuculuyor. Bir `Flexible`
                  // eklenince kalan dikey boslugu dolduruyor ve panel her
                  // zaman tam pencere yuksekliginde kaliyordu. Icerik cok
                  // uzun bir sekmede ( orn. Davranis) tasarsa asagidaki
                  // `ListView` kendi icinde kayar.
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Surum satiri: baslikla icerik arasinda, tam genislikte.
                      // Alt bantta degil — orada `Kaydet` ve durum metni
                      // zaten yer aliyor ve satir tasiyordu.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(28, 4, 28, 8),
                        child: _VersionRow(engineVersion: widget.engineVersion),
                      ),
                        // Dikey `Flexible` degil dogrudan `Row`: `Flexible`
                        // kalan boslugu doldurdugu icin panel her zaman tam
                        // pencere yuksekliginde kaliyordu. Icerik kendi
                        // yuksekliginde olmali; cok uzun sekmelerde asagidaki
                        // `Flexible` sarmalayicisi listeyi kaydirilir yapar.
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
                              child: _TabRail(
                                index: _tab,
                                onChanged: (value) => setState(() => _tab = value),
                              ),
                            ),
                            Expanded(
                              child: ListView(
                                shrinkWrap: true,
                                padding: const EdgeInsets.fromLTRB(0, 0, 8, 4),
                                children: [
                                  // Aktif sekme dogrudan kurulur; burada
                                  // `IndexedStack` KULLANILMAZ. O widget tum
                                  // sekmeleri ayakta tutar ve en UZUN kardesine
                                  // gore boyutlanir: About'un lisans metni en
                                  // uzun oldugu icin kisa bir sekmede (Genel)
                                  // panelin alt yarisi bos kaliyordu ve
                                  // yukaridaki `maxHeight` yorumu yalan
                                  // soyluyordu. Sekme durumu zaten
                                  // `_SettingsPanelState`te tutulur; burada
                                  // kaybolan tek sey About'un kaydirma konumu.
                                  switch (_tab) {
                                    0 => _generalTab(),
                                    1 => _downloadsTab(),
                                    2 => _behaviourTab(),
                                    _ => _aboutTab(),
                                  },
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  // Alt bant: "Temizle", durum, Kaydet. Surum satiri ayri bir
                  // satirda, panelin geri kalanindan bagimsiz duruyor; ikisini
                  // ayni satira koymak yalnizca tasma yaratti (alt bant zaten
                  // `Kaydet` + durum metni tasiyor).
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 12, 28, 14),
                    child: Row(
                      children: [
                        HoverSurface(
                          onTap: _clearCompleted,
                          background: Colors.transparent,
                          hoverBackground: Serene.surfaceContainer,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: Text(
                            T.clearCompletedLabel,
                            style: body(
                              13,
                              weight: FontWeight.w500,
                              color: Serene.secondary,
                            ),
                          ),
                        ),
                        const Spacer(),
                        if (_status != null) ...[
                          Flexible(
                            child: Text(
                              _status!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: body(12, color: _statusColor),
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Opacity(
                          opacity: _busy ? 0.6 : 1,
                          child: HoverSurface(
                            onTap: _busy ? null : _save,
                            radius: 999,
                            background: Serene.primary,
                            hoverBackground: Serene.primaryHover,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 10,
                            ),
                            child: Text(
                              T.save,
                              style: body(
                                13,
                                weight: FontWeight.w500,
                                color: Serene.onPrimary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Hakkinda sekmesinde etiket + deger satiri (surum, motor surumu).
class _AboutRow extends StatelessWidget {
  const _AboutRow({
    required this.label,
    required this.value,
    this.monoFont = false,
  });

  final String label;
  final String value;

  /// Deger monospace mi? Surum ve yol gibi degerler icin evet, duz metin icin hayir.
  /// Alan `mono` olarak adlandirilamaz: dosyadaki `mono(...)` tipografi
  /// fonksiyonuyla cakisir.
  final bool monoFont;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: body(12, color: Serene.secondary),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: monoFont
                ? mono(12, color: Serene.onSurface)
                : body(12, color: Serene.onSurface),
          ),
        ),
      ],
    );
  }
}

/// Hakkinda sekmesinde tiklanabilir baglanti satiri.
///
/// Baglanti acma cagrisi Rust tarafinda: `url_launcher` gibi bir paket eklemek
/// yerine Windows'un `cmd /c start` mekanizmasi kullaniliyor, boylece yeni
/// bagimlilik getirilmiyor. Yalnizca http(s) adresleri kabul edilir.
class _AboutLink extends StatelessWidget {
  const _AboutLink({
    required this.label,
    required this.value,
    required this.url,
  });

  final String label;
  final String value;
  final String url;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: body(12, color: Serene.secondary),
          ),
        ),
        Expanded(
          child: HoverSurface(
            onTap: () => ffi.openExternal(url: url),
            background: Colors.transparent,
            hoverBackground: Serene.surfaceContainer,
            radius: Serene.radiusField,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono(12, color: Serene.primary),
                  ),
                ),
                const SizedBox(width: 6),
                SIcon('open_in_new', size: 13, color: Serene.primary),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Ayarlar panelinin solundaki sekme listesi.
///
/// Duz metin listesi; secili olan yesil bir arka planla isaretleniyor.
/// Ikon kullanilmadi: ucu de metin oldugu icin ikon ne yapilacagini
/// soylemeye katki saglamiyor, yalnizca yer kaplardi.
class _TabRail extends StatelessWidget {
  const _TabRail({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final labels = [
      T.tabGeneral,
      T.tabDownloads,
      T.tabBehaviour,
      T.tabAbout,
    ];
    // Sabit genislik: bu, yatay bir Row icindeki Column. `stretch` ve genislik
    // verilmezse Flutter'a sinirsiz (Infinity) genislik gecer ve layout coker.
    return SizedBox(
      width: 128,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0) const SizedBox(height: 2),
            HoverSurface(
              onTap: () => onChanged(i),
              radius: Serene.radiusField,
              background: i == index
                  ? Serene.primary.withValues(alpha: 0.10)
                  : Colors.transparent,
              hoverBackground: i == index
                  ? Serene.primary.withValues(alpha: 0.14)
                  : Serene.surfaceContainer,
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              child: Text(
                labels[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: body(
                  13,
                  weight: i == index ? FontWeight.w600 : FontWeight.w500,
                  color: i == index ? Serene.primary : Serene.secondary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Ayarlar panelinin altindaki surum satiri.
///
/// Surum ust bardan kaldirildiktan sonra buraya tasindi. Iki degeri birlikte
/// gosterir: uygulamanin surumu (`pubspec.yaml`'dan, build.rs araciligiyla)
/// ve motorun surumu (`engine_version`). Ikisi ayri seyler ve cogu kez
/// karistirilir; ayri gostermek hangisinin ne oldugunu netlestirir.
class _VersionRow extends StatefulWidget {
  const _VersionRow({required this.engineVersion});

  final String engineVersion;

  @override
  State<_VersionRow> createState() => _VersionRowState();
}

class _VersionRowState extends State<_VersionRow> {
  bool _copied = false;

  /// Uygulama surumu. Motor FFI ile okunur; **bir kez** burada, `initState`
  /// icinde alinir. Surum sabittir, her `build`de yeniden okumaya gerek yok
  /// (ve `build` icinde FFI cagrisi hem pahali hem de FFI baslatilmamis
  /// testlerde cokmeye yol acar).
  late final String _version = _readVersion();

  static String _readVersion() {
    try {
      return ffi.appVersion();
    } catch (_) {
      // Motor kurulmamis (birim testi). Bos birakmak yerine bilinen bir
      // deger gostermek, ayarlari acan gercek kullanicinin motora erisimi
      // oldugunu varsaymak daha iyi olsa da, burada sadece **gorunur
      // kalan** bir hatadir. Bos birakmak testleri ve motor-oncesi
      // cerceveleri saglam tutar.
      return '';
    }
  }

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final version = _version;
    if (version.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: version));
      if (!mounted) return;
      setState(() => _copied = true);
      messenger?.showSnackBar(
        SnackBar(
          content: Text('${T.versionLabel} $version - ${T.versionCopied}'),
          duration: const Duration(milliseconds: 1800),
        ),
      );
      // Geri donus: "kopyalandi" hali sonsuza kadar kalmasin.
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      if (mounted) setState(() => _copied = false);
    } catch (_) {
      // Panoya yazilamadi (orn. baska bir uygulama kilitli): ayari engelleme.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.75,
      child: HoverSurface(
        onTap: _copy,
        background: Colors.transparent,
        hoverBackground: Serene.surfaceContainer,
        radius: Serene.radiusTile,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(T.versionLabel, style: body(12, color: Serene.secondary)),
            const SizedBox(width: 8),
            // `Flexible` + `ellipsis`: alt bant daraldiginda surum metni
            // tasmaz, kirpilir. Duz `Text` dar panellerde tasma yapiyordu.
            Flexible(
              child: Text(
                _copied ? T.versionCopied : _version,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono(12, color: Serene.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${T.versionEngine} ${widget.engineVersion}',
              style: body(11, color: Serene.outline),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cok secenekli secici: web arayuzundeki `select`in karsiligi, ayni satirda
/// duran ve secilisi birincil renkle boyanan dugmeler. Gorunum ve dil ayni
/// bicimi paylasir.
class _SegmentedPicker<T> extends StatelessWidget {
  const _SegmentedPicker({
    required this.value,
    required this.values,
    required this.title,
    required this.onChanged,
  });

  final T value;
  final List<T> values;
  final String Function(T value) title;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Serene.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Serene.radiusField),
        border: Border.all(color: Serene.borderInput),
      ),
      child: Row(
        children: [
          for (final option in values) ...[
            if (option != values.first) const SizedBox(width: 4),
            Expanded(
              child: HoverSurface(
                onTap: () => onChanged(option),
                radius: 9,
                background:
                    option == value ? Serene.primary : Colors.transparent,
                hoverBackground: option == value
                    ? Serene.primaryHover
                    : Serene.surfaceContainer,
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Center(
                  child: Text(
                    title(option),
                    style: body(
                      12,
                      weight: FontWeight.w500,
                      color: option == value
                          ? Serene.onPrimary
                          : Serene.secondary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Sayi alani: `min`/`max` niteliklerinin karsiligi 1..16 arasi tam sayi.
class _NumberField extends StatelessWidget {
  const _NumberField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: Serene.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Serene.radiusField),
        border: Border.all(color: Serene.borderInput),
      ),
      child: TextField(
        controller: controller,
        cursorColor: Serene.primary,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: body(13),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
        ),
      ),
    );
  }
}

/// Etiket + alt aciklama + kutucuk; webdeki `label` satirlarinin karsiligi.
class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.title,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return HoverSurface(
      onTap: () => onChanged(!value),
      background: Serene.surfaceContainerLow,
      hoverBackground: Serene.surfaceContainerLow,
      radius: Serene.radiusTile,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      border: Border.all(color: Serene.outlineVariant.withValues(alpha: 0.5)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: body(13, weight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: body(11, color: Serene.secondary, height: 1.35),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 24,
            height: 24,
            child: FittedBox(
              child: Checkbox(
                value: value,
                onChanged: (next) => onChanged(next ?? false),
                activeColor: Serene.primary,
                checkColor: Serene.onPrimary,
                side: BorderSide(color: Serene.outline),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CloseSettings extends Intent {
  const _CloseSettings();
}

/// Web arayuzundeki sayi alanlarinin davranisi: bos ya da gecersiz girdi
/// mevcut degeri korur, `min`/`max` niteliginin yerine 1..16 kisiti gecilir.
int parseCount(String? text, int fallback) {
  final value = int.tryParse((text ?? '').trim());
  if (value == null) return fallback;
  if (value < 1) return 1;
  if (value > 16) return 16;
  return value;
}
