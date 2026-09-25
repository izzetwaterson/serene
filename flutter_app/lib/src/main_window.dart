import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_theme.dart';
import 'cards.dart';
import 'data.dart';
import 'demo.dart';
import 'folder_picker.dart';
import 'format.dart';
import 'handoff.dart';
import 'rust/api/commands.dart' as ffi;
import 'rust/api/dto.dart' as engine;
import 'rust/api/events.dart' as ffi;
import 'rust/api/lifecycle.dart' as ffi;
import 'settings_view.dart';
import 'theme.dart';
import 'widgets.dart';

/// Ana pencere: Tauri arayuzunun Flutter karsiligi.
class MainWindow extends StatefulWidget {
  const MainWindow({super.key, this.demoOn = false, this.settingsOn = false});

  final bool demoOn;

  /// Ayarlar katmani pencereyle birlikte acilir; kosumlar arayuzu tiklamadan
  /// gosterebilmek icin `--settings` bayragiyla verilir.
  final bool settingsOn;

  @override
  State<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends State<MainWindow>
    with WindowListener, WidgetsBindingObserver {
  /// Motorun tam listesi; demo acikken ust gosterilen sahte gorevler ayridir.
  List<Task> _real = [];
  final List<Task> _demo = demoTasks();
  List<CaptureItem> _captures = [];

  /// Ilerleme paketleri listeyi bastan cizmeden yerinde islenir.
  final Map<String, Task> _byId = {};

  late Settings _settings;

  String _filter = 'all';
  String? _category;
  String _view = 'tasks';
  String _query = '';

  bool _demoOn = false;
  bool _bridgeUp = false;
  bool _maximized = false;
  bool _showSettings = false;

  /// Yalnizca siradaki indirmeler icin secilen klasor; ayarlara dokunmaz.
  String? _destOverride;
  DiskUsage? _disk;
  String? _notice;

  final TextEditingController _search = TextEditingController();
  final TextEditingController _url = TextEditingController();

  Timer? _clock;
  Timer? _noticeTimer;
  final List<StreamSubscription<Object?>> _streams = [];

  TrayIcon? _tray;

  /// "Cikis" secildiginde pencere X'e basilmis gibi tepsiye gizlenmesin.
  bool _quitting = false;

  /// Onay bekleyen devralmalarin sirasi ve acik olan harici pencere.
  final HandoffQueue _handoffs = HandoffQueue();
  Process? _handoffProc;

  List<Task> get _tasks => _demoOn ? [..._demo, ..._real] : _real;

  @override
  void initState() {
    super.initState();
    _demoOn = widget.demoOn;
    _showSettings = widget.settingsOn;
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);

    // Palet globaldir ve degistiginde agac kendiliginden kurulmaz: bu
    // pencerenin govdesini kuran `build` yeniden calismali ki yeni renkler
    // okunsun. Ayarlar katmani da ayni anda modu yazar.
    appThemeMode.addListener(_onThemeChanged);

    // Motor bu noktada ayaaga kalkmis olur: main() RustLib.init ve bootEngine
    // icin bekletilmis bir Future'i bitirmeden pencereyi boyamaz.
    _settings = Settings.fromEngine(ffi.getSettings());
    _applyTasks(ffi.listTasks());
    _applyCaptures(ffi.listCaptures());

    _streams.add(
      ffi.watchTasks().listen((raw) {
        _applyTasks(raw);
        _pumpHandoffs();
      }),
    );
    _streams.add(ffi.watchProgress().listen(_applyProgress));
    _streams.add(ffi.watchCaptures().listen(_applyCaptures));
    // Ikinci acilis ya da eklentideki "Serene'yi Ac": pencere one gelir.
    _streams.add(ffi.watchPresent().listen((_) => _present()));
    // Yeni bir tarayici devralmasi: onay penceresi sirasina girer.
    //
    // Iki ayri FRB akisi sirayi garanti etmez: olay, gorevi tasiyan liste
    // yayinini gecebilir. Bu yuzden sira once motorun kendi listesinden
    // tazelenir; yoksa `sync` gorevi "artik onay beklemiyor" sanip siradan
    // duser ve pencere hic acilmaz.
    _streams.add(
      ffi.watchHandoff().listen((task) {
        _applyTasks(ffi.listTasks());
        _handoffs.request(task.id);
        _pumpHandoffs();
      }),
    );

    // Kapanip acildiktan sonra onay bekleyen gorevler yeniden sorulur.
    for (final task in _real) {
      if (task.pending) _handoffs.request(task.id);
    }
    _pumpHandoffs();

    _setupShell();
    _checkBridge();
    _bridgeClock = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _checkBridge(),
    );
    _loadDisk();
    _syncDemoClock();
  }

  Timer? _bridgeClock;

  /// Pencereyi tepsiyle konusur hale getirir.
  Future<void> _setupShell() async {
    // Kapanma istegini biz yonlendirelim: aksa Windows pencereyi hemen yok eder.
    await windowManager.setPreventClose(true);
    _setupTray();
  }

  void _setupTray() {
    final icon = TrayIcon.create();
    if (icon == null) return;

    icon.icon = ImageAsset.fromAsset('assets/icons/serene_tray.png');
    icon.setTooltip('Serene');

    final menu = Menu.create();
    if (menu != null) {
      menu.addItem(_trayItem('Pencereyi Göster', _present));
      menu.addItem(
        _trayItem('Tümünü Duraklat', () async {
          ffi.pauseAllDownloads();
          await _present();
        }),
      );
      menu.addItem(
        _trayItem('Ayarlar', () async {
          await _present();
          _openSettings();
        }),
      );
      menu.addSeparator();
      menu.addItem(_trayItem('Çıkış', _quit));
      icon.setContextMenu(menu);
    }

    icon.addListener((event) {
      if (event is TrayIconClickedEvent) _present();
    });
    icon.setVisible(true);
    _tray = icon;
  }

  MenuItem? _trayItem(String label, Future<void> Function() onTap) {
    final item = MenuItem.createWithLabelAndType(label, MenuItemType.normal);
    item?.addListener((event) {
      if (event is MenuItemClickedEvent) onTap();
    });
    return item;
  }

  Future<void> _present() async {
    // restore() kucultulmus pencereyi geri alir; buyutulmus pencereyi de
    // eski boyutuna dusurdugu icin yalnizca kucuk durumda cagrilir.
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  /// Gercek kapanis: kopru kaydini sil, sonra pencereyi yok et.
  Future<void> _quit() async {
    _quitting = true;
    ffi.stopBridge();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
    exit(0);
  }

  @override
  Future<void> onWindowClose() async {
    if (_quitting) return;
    if (!_settings.closeToTray) {
      await _quit();
      return;
    }
    // Tepsiye gizle: indirmeler surer, pencere simgeden geri gelir.
    await windowManager.hide();
  }

  @override
  void dispose() {
    _clock?.cancel();
    _bridgeClock?.cancel();
    _noticeTimer?.cancel();
    for (final sub in _streams) {
      sub.cancel();
    }
    _tray?.setVisible(false);
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    appThemeMode.removeListener(_onThemeChanged);
    _search.dispose();
    _url.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  /// Yalnizca "Sistem" seciliyken is gorur: elle secilen tema isletim
  /// sisteminin bildirdigi parlakliktan bagimsizdir.
  @override
  void didChangePlatformBrightness() {
    if (appThemeMode.value == ThemeMode.system) {
      applyThemeMode(ThemeMode.system);
    }
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  void _applyTasks(List<engine.Task> raw) {
    if (!mounted) return;
    setState(() {
      _real = raw.map(Task.fromEngine).toList();
      _byId
        ..clear()
        ..addAll({for (final task in _real) task.id: task});
    });
  }

  void _applyCaptures(List<engine.Capture> raw) {
    if (!mounted) return;
    setState(() => _captures = raw.map(CaptureItem.fromEngine).toList());
  }

  /// Ticker yalnizca inen gorevleri taşir; tam liste yeniden cizilmez.
  void _applyProgress(List<engine.Progress> ticks) {
    if (!mounted) return;
    var changed = false;
    for (final tick in ticks) {
      final task = _byId[tick.id];
      if (task == null) continue;
      task
        ..downloaded = tick.downloaded.toInt()
        ..speed = tick.speed;
      changed = true;
    }
    if (changed) setState(() {});
  }

  /// Demo gorevler kendi kendine ilerler; motor kapaliyken de canli gorunsun
  /// diye yalnizca demo acikken saat calisir.
  void _syncDemoClock() {
    _clock?.cancel();
    _clock = null;
    if (!_demoOn) return;
    _clock = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      setState(() => tickDemoTasks(_demo, 0.2));
    });
  }

  Future<void> _checkBridge() async {
    final status = ffi.bridgeStatus();
    if (!mounted) return;
    setState(() => _bridgeUp = status.clients > 0);
  }

  Future<void> _loadDisk() async {
    try {
      final usage = await ffi.getDiskUsage();
      if (!mounted) return;
      setState(() {
        _disk = DiskUsage(
          // Motor hedef klasoru dondurur; kart eski arayuz gibi surucuyu yazar.
          mount:
              RegExp(r'^([A-Za-z]:)').firstMatch(usage.mount)?.group(1) ??
              usage.mount,
          total: usage.total.toInt(),
          free: usage.free.toInt(),
          used: usage.used.toInt(),
        );
      });
    } catch (_) {
      /* disk okunamazsa kart bos kalir */
    }
  }

  /// Ayarlar katmani: taslak motorun guncel ayarlarindan dolurulur.
  void _openSettings() => setState(() => _showSettings = true);

  void _closeSettings() => setState(() => _showSettings = false);

  /// Kaydedilen ayar arayuzde kullanilir; disk karti yeni hedef klasore bakar.
  void _applySettings(Settings saved) {
    setState(() => _settings = saved);
    // Kayit tek dogru kaynaktir: panel secim aninda da boyasa, burada
    // motorun kabul ettigi deger pekistirilir.
    applyThemeSetting(saved.theme);
    _loadDisk();
  }

  /// Siradaki indirmeler icin gecici hedef; ayarlardaki klasoru degistirmez.
  Future<void> _pickDest() async {
    final picked = await pickFolder(
      title: 'Bu indirme için klasör seçin',
      initialDirectory: _settings.downloadDir,
    );
    if (picked == null || !mounted) return;
    setState(() => _destOverride = picked);
    _notify('Bu indirme şuraya kaydedilecek: $picked');
  }

  void _notify(String message) {
    // Cagrilari komutlarin ardindan gelir; pencere o sirada kapanmis olabilir.
    if (!mounted) return;
    _noticeTimer?.cancel();
    setState(() => _notice = message);
    _noticeTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  /// Demo gorevler yerinde degistirilebilir; gercek gorevlere dokunulmaz.
  Task? _mutable(String id) {
    if (!_demoOn) return null;
    for (final task in _demo) {
      if (task.id == id) return task;
    }
    return null;
  }

  Future<void> _runAction(Task task, String action) async {
    if (action == 'info') {
      _requestHandoff(task);
      return;
    }
    final live = _mutable(task.id);
    if (live != null) {
      setState(() {
        switch (action) {
          case 'pause':
            live.status = 'paused';
            live.speed = 0;
          case 'resume':
            live.status = 'downloading';
            live.speed = 2 * 1024 * 1024;
            live.pending = false;
          case 'remove':
            _demo.removeWhere((item) => item.id == live.id);
          case 'retry':
            live.status = 'downloading';
            live.speed = 1024 * 1024;
            live.error = null;
          default:
            _notify('"$action" islemi taninmiyor');
        }
      });
      return;
    }

    try {
      switch (action) {
        case 'pause':
          await ffi.pauseDownload(id: task.id);
        case 'resume':
          await ffi.resumeDownload(id: task.id);
        case 'retry':
          await ffi.retryDownload(id: task.id);
        case 'remove':
          await ffi.removeDownload(id: task.id, deleteFile: false);
        case 'open':
          await ffi.openTaskFile(id: task.id);
        case 'reveal':
          await ffi.revealTaskFile(id: task.id);
        default:
          _notify('"$action" islemi taninmiyor');
      }
    } catch (error) {
      _notify(engineReason(error));
    }
  }

  Future<void> _runCaptureAction(CaptureItem item, String action) async {
    try {
      switch (action) {
        case 'download':
          await ffi.downloadCapture(id: item.id, destDir: _destOverride);
          if (!mounted) return;
          // Kart listesinin oldugu yere don: yakalama artik goreve donusti.
          setState(() => _view = 'tasks');
        case 'dismiss':
          await ffi.dismissCapture(id: item.id);
        default:
          _notify('"$action" islemi taninmiyor');
      }
    } catch (error) {
      _notify(engineReason(error));
    }
  }

  Future<void> _clearCaptures() async {
    try {
      final count = await ffi.clearCaptures();
      _notify('$count yakalama temizlendi');
    } catch (error) {
      _notify(engineReason(error));
    }
  }

  /// Gorevi onay siralarina alir; listedeki "Bilgileri Aç" da buradan gecirilir.
  void _requestHandoff(Task task) {
    _handoffs.request(task.id);
    _pumpHandoffs();
  }

  /// Siradaki onay bekleyen gorev icin harici pencereyi acar.
  ///
  /// Gorev baska bir yerden onaylanir ya da silinirse acik pencere kapatilir;
  /// boylece pencere asla yarim kalmis bir karari sormaz.
  void _pumpHandoffs() {
    final pending = {
      for (final task in _tasks)
        if (task.pending) task.id,
    };
    final stale = _handoffs.sync(pending);
    if (stale != null) {
      _handoffProc?.kill();
      _handoffProc = null;
    }

    final id = _handoffs.take();
    if (id == null) return;
    final task = _taskById(id);
    if (task == null) {
      _handoffs.close(id);
      return;
    }
    _spawnHandoff(task);
  }

  Task? _taskById(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  /// Onay penceresi kendi surecinde acilir; karari beklenir, cunku kapanisin
  /// haberi siradaki onayi one getirir. `detached` kipinde `exitCode` yoktur,
  /// bu yuzden borular normal kipde acilip bosaltilir.
  Future<void> _spawnHandoff(Task task) async {
    final payload = base64Url.encode(utf8.encode(jsonEncode(task.toJson())));
    try {
      final process = await Process.start(Platform.resolvedExecutable, [
        '--handoff=$payload',
        if (_demoOn) '--handoff-demo',
        '--handoff-theme=${themeModeSetting(appThemeMode.value)}',
      ]);
      unawaited(process.stdout.drain());
      unawaited(process.stderr.drain());
      _handoffProc = process;
      await process.exitCode;
    } catch (_) {
      /* surec acilamazsa da sira kilitlenmesin */
    }
    _handoffClosed(task.id);
  }

  void _handoffClosed(String id) {
    _handoffProc = null;
    _handoffs.close(id);
    if (mounted) _pumpHandoffs();
  }

  Future<void> _submitUrl() async {
    final value = _url.text.trim();
    if (value.isEmpty) return;
    _url.clear();
    try {
      await ffi.addDownload(
        url: value,
        destDir: _destOverride,
        referer: null,
        cookie: null,
        userAgent: null,
        kind: null,
        source: 'flutter',
      );
    } catch (error) {
      _notify(engineReason(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _tasks;
    final speed = tasks
        .where((task) => task.status == 'downloading')
        .fold<double>(0, (sum, task) => sum + task.speed);

    return Scaffold(
      backgroundColor: Serene.background,
      body: Stack(
        children: [
          Column(
            children: [
              Header(
                bridgeUp: _bridgeUp,
                speed: speed,
                maximized: _maximized,
                search: _search,
                onQuery: (value) => setState(() => _query = value),
                onSettings: _openSettings,
                onMinimize: windowManager.minimize,
                onMaximize: () async {
                  if (await windowManager.isMaximized()) {
                    await windowManager.unmaximize();
                  } else {
                    await windowManager.maximize();
                  }
                },
                onClose: windowManager.close,
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1280),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(32, 32, 32, 32),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Sidebar(
                            tasks: tasks,
                            captures: _captures,
                            settings: _settings,
                            disk: _disk,
                            filter: _filter,
                            category: _category,
                            view: _view,
                            demoOn: _demoOn,
                            onNewDownload: () => _url.text.isEmpty
                                ? _notify(
                                    'Bağlantı alanına bir adres yapıştırın',
                                  )
                                : _submitUrl(),
                            onFilter: (value) => setState(() {
                              _filter = value;
                              _category = null;
                              _view = 'tasks';
                            }),
                            onCategory: (value) => setState(() {
                              _category = value;
                              _view = 'tasks';
                            }),
                            onCaptures: () =>
                                setState(() => _view = 'captures'),
                            onDemo: (value) {
                              setState(() => _demoOn = value);
                              _syncDemoClock();
                            },
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            child: _view == 'captures'
                                ? CapturesPane(
                                    items: _captures,
                                    notice: _notice,
                                    onAction: _runCaptureAction,
                                    onClear: _clearCaptures,
                                  )
                                : TaskPane(
                                    tasks: tasks,
                                    filter: _filter,
                                    category: _category,
                                    query: _query,
                                    settings: _settings,
                                    notice: _notice,
                                    url: _url,
                                    onQueryJump: (value) => setState(() {
                                      _filter = value;
                                      _category = null;
                                    }),
                                    onSubmitUrl: _submitUrl,
                                    onAction: _runAction,
                                    destOverride: _destOverride,
                                    onPickFolder: _pickDest,
                                    onClearOverride: () =>
                                        setState(() => _destOverride = null),
                                    onOpenSettings: _openSettings,
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_showSettings)
            Positioned.fill(
              child: SettingsLayer(
                settings: _settings,
                onClose: _closeSettings,
                onSaved: _applySettings,
              ),
            ),
        ],
      ),
    );
  }
}

/// Disk bilgisi.
class DiskUsage {
  const DiskUsage({
    required this.mount,
    required this.total,
    required this.free,
    required this.used,
  });

  final String mount;
  final int total;
  final int free;
  final int used;
}

/// Ust bar.
class Header extends StatelessWidget {
  const Header({
    super.key,
    required this.bridgeUp,
    required this.speed,
    required this.maximized,
    required this.search,
    required this.onQuery,
    required this.onSettings,
    required this.onMinimize,
    required this.onMaximize,
    required this.onClose,
  });

  final bool bridgeUp;
  final double speed;
  final bool maximized;
  final TextEditingController search;
  final ValueChanged<String> onQuery;
  final VoidCallback onSettings;
  final VoidCallback onMinimize;
  final VoidCallback onMaximize;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        decoration: BoxDecoration(
          color: Serene.background,
          border: Border(bottom: BorderSide(color: Serene.borderSoft)),
        ),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Serene.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: SIcon('spa', size: 15, color: Serene.primary),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'Serene',
              style: head(15, weight: FontWeight.w500, letterSpacing: -0.3),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Serene.surfaceContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'v0.1',
                style: body(
                  11,
                  weight: FontWeight.w500,
                  color: Serene.secondary,
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 448),
                  child: _SearchField(controller: search, onChanged: onQuery),
                ),
              ),
            ),
            _Pill(
              dot: bridgeUp ? Serene.primary : Serene.outline,
              label: bridgeUp ? 'Tarayıcı bağlı' : 'Tarayıcı yok',
            ),
            if (speed > 0) ...[
              const SizedBox(width: 12),
              _Pill(
                dot: Serene.primary,
                label: fmtSpeed(speed),
                monoFont: true,
                pulse: true,
              ),
            ],
            const SizedBox(width: 12),
            CircleButton(
              icon: 'tune',
              title: 'Ayarlar',
              size: 32,
              iconSize: 17,
              background: Serene.surfaceContainer,
              hoverBackground: Serene.surfaceContainerHigh,
              foreground: Serene.secondary,
              border: Serene.borderInput,
              onTap: onSettings,
            ),
            const SizedBox(width: 12),
            Tooltip(
              message: 'Yerel profil',
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomLeft,
                    end: Alignment.topRight,
                    colors: [
                      Serene.primary.withValues(alpha: 0.3),
                      Serene.tertiary.withValues(alpha: 0.3),
                    ],
                  ),
                  shape: BoxShape.circle,
                  border: Border.all(color: Serene.borderPrimary),
                ),
                child: Center(
                  child: Text(
                    'EF',
                    style: body(
                      12,
                      weight: FontWeight.w600,
                      color: Serene.primary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 20),
            Container(
              padding: const EdgeInsets.only(left: 8),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: Serene.borderInput)),
              ),
              child: Row(
                children: [
                  CircleButton(
                    icon: 'remove',
                    title: 'Küçült',
                    size: 32,
                    iconSize: 17,
                    background: Serene.surfaceContainer,
                    hoverBackground: Serene.surfaceContainerHigh,
                    foreground: Serene.secondary,
                    border: Serene.borderInput,
                    onTap: onMinimize,
                  ),
                  const SizedBox(width: 4),
                  CircleButton(
                    icon: maximized ? 'filter_none' : 'crop_square',
                    title: maximized ? 'Geri Al' : 'Büyüt',
                    size: 32,
                    iconSize: 17,
                    background: Serene.surfaceContainer,
                    hoverBackground: Serene.surfaceContainerHigh,
                    foreground: Serene.secondary,
                    border: Serene.borderInput,
                    onTap: onMaximize,
                  ),
                  const SizedBox(width: 4),
                  CircleButton(
                    icon: 'close',
                    title: 'Kapat',
                    size: 32,
                    iconSize: 17,
                    background: Serene.surfaceContainer,
                    hoverBackground: Serene.errorContainer,
                    foreground: Serene.secondary,
                    border: Serene.borderInput,
                    onTap: onClose,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Serene.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Serene.borderInput),
      ),
      child: Row(
        children: [
          SIcon('search', size: 17, color: Serene.outline),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              cursorColor: Serene.primary,
              style: body(13),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: "İndirilenleri ara (örn: 'Nature')...",
                hintStyle: body(
                  13,
                  color: Serene.outline.withValues(alpha: 0.8),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Serene.surfaceContainer,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Serene.borderInput),
            ),
            child: Text('Ctrl K', style: mono(10, color: Serene.outline)),
          ),
        ],
      ),
    );
  }
}

/// Ust bardaki bilgi rozetleri.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.dot,
    required this.label,
    this.monoFont = false,
    this.pulse = false,
  });

  final Color dot;
  final String label;
  final bool monoFont;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Serene.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Serene.borderInput),
        boxShadow: Serene.shadowSoft,
      ),
      child: Row(
        children: [
          pulse
              ? const _PulseDot()
              : Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
          const SizedBox(width: 8),
          Text(
            label,
            style: monoFont
                ? mono(12, color: Serene.secondary)
                : body(12, color: Serene.secondary),
          ),
        ],
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.3).animate(_controller),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: Serene.primary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Sol menu.
class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.tasks,
    required this.captures,
    required this.settings,
    required this.disk,
    required this.filter,
    required this.category,
    required this.view,
    required this.demoOn,
    required this.onNewDownload,
    required this.onFilter,
    required this.onCategory,
    required this.onCaptures,
    required this.onDemo,
  });

  final List<Task> tasks;
  final List<CaptureItem> captures;
  final Settings settings;
  final DiskUsage? disk;
  final String filter;
  final String? category;
  final String view;
  final bool demoOn;
  final VoidCallback onNewDownload;
  final ValueChanged<String> onFilter;
  final ValueChanged<String> onCategory;
  final VoidCallback onCaptures;
  final ValueChanged<bool> onDemo;

  int _count(String key) => switch (key) {
    'active' => tasks.where((task) => inProgress.contains(task.status)).length,
    'completed' => tasks.where((task) => task.status == 'completed').length,
    'queued' => tasks.where((task) => task.status == 'queued').length,
    'failed' => tasks.where((task) => task.status == 'failed').length,
    _ => tasks.length,
  };

  @override
  Widget build(BuildContext context) {
    const queues = [
      ('all', 'Tüm İndirmeler', 'cloud_queue'),
      ('active', 'Devam Edenler', 'autorenew'),
      ('completed', 'Tamamlananlar', 'task_alt'),
      ('queued', 'Kuyrukta', 'hourglass_bottom'),
      ('failed', 'Hata Verenler', 'info'),
    ];
    const cats = [
      ('video', 'Videolar', 'movie'),
      ('audio', 'Sesler', 'music_note'),
      ('document', 'Belgeler', 'description'),
      ('software', 'Yazılımlar', 'code'),
      ('archive', 'Sıkıştırılmış', 'folder_zip'),
      ('image', 'Görseller', 'image'),
    ];

    return SizedBox(
      width: 240,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          children: [
            HoverSurface(
              onTap: onNewDownload,
              radius: Serene.radiusTile,
              background: Serene.primary,
              hoverBackground: Serene.primaryHoverStrong,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SIcon('add_circle', size: 19, color: Serene.onPrimary),
                  const SizedBox(width: 10),
                  Text(
                    'Yeni İndirme Başlat',
                    style: body(
                      14,
                      weight: FontWeight.w500,
                      color: Serene.onPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Serene.surfaceContainerLow,
                borderRadius: BorderRadius.circular(Serene.radiusCard),
                border: Border.all(color: Serene.borderSoft),
                boxShadow: Serene.shadowSoft,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _GroupLabel('Kuyruklar'),
                  for (final (key, label, icon) in queues) ...[
                    NavItem(
                      icon: icon,
                      label: label,
                      count: _count(key),
                      active:
                          view == 'tasks' && category == null && filter == key,
                      onTap: () => onFilter(key),
                    ),
                    const SizedBox(height: 4),
                  ],
                  NavItem(
                    icon: 'travel_explore',
                    label: 'Tarayıcıdan',
                    count: captures.length,
                    active: view == 'captures',
                    onTap: onCaptures,
                  ),
                  Container(
                    height: 1,
                    margin: const EdgeInsets.symmetric(vertical: 12),
                    color: Serene.borderSoft,
                  ),
                  _GroupLabel('Kategoriler', dense: true),
                  for (final (key, label, icon) in cats)
                    NavItem(
                      icon: icon,
                      label: label,
                      count: tasks.where((task) => task.category == key).length,
                      active: view == 'tasks' && category == key,
                      compact: true,
                      onTap: () => onCategory(key),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _DiskCard(disk: disk, retry: null),
            const SizedBox(height: 16),
            _DemoSwitch(value: demoOn, onChanged: onDemo),
          ],
        ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text, {this.dense = false});

  final String text;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12, dense ? 6 : 8, 12, dense ? 6 : 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text.toUpperCase(),
          style: body(
            11,
            weight: FontWeight.w600,
            color: Serene.outline,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }
}

/// Sol menudeki tek satir (nav-item / cat-item).
class NavItem extends StatelessWidget {
  const NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
    this.compact = false,
  });

  final String icon;
  final String label;
  final int count;
  final bool active;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tone = active ? Serene.primary : Serene.onSurfaceVariant;
    return HoverSurface(
      onTap: onTap,
      radius: Serene.radiusTile,
      background: active ? Serene.surfaceContainerHigh : Colors.transparent,
      hoverBackground: Serene.surfaceContainer,
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: compact ? 8 : 10),
      child: Row(
        children: [
          SIcon(
            icon,
            size: compact ? 17 : 18,
            color: active ? Serene.primary : Serene.secondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: body(
                compact ? 13 : 13.5,
                weight: active ? FontWeight.w500 : FontWeight.w400,
                color: tone,
              ),
            ),
          ),
          Text(
            '$count',
            style: mono(
              compact ? 11 : 12,
              weight: FontWeight.w600,
              color: active ? Serene.primary : Serene.outline,
            ),
          ),
        ],
      ),
    );
  }
}

class _DiskCard extends StatelessWidget {
  const _DiskCard({required this.disk, required this.retry});

  final DiskUsage? disk;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) {
    final usage = disk;
    final percent = usage == null || usage.total == 0
        ? 0.0
        : (usage.used / usage.total * 100).clamp(0, 100).toDouble();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Serene.secondaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(Serene.radiusCard),
        border: Border.all(color: Serene.borderFaint),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SIcon('hard_drive', size: 15, color: Serene.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  usage == null ? 'Disk' : '${usage.mount} sürücüsü',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: body(
                    12,
                    weight: FontWeight.w500,
                    color: Serene.onSecondaryContainer,
                  ),
                ),
              ),
              Text(
                usage == null ? '—' : '%${percent.round()}',
                style: mono(12, color: Serene.onSecondaryContainer),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            height: 8,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: Serene.surfaceDim,
              borderRadius: BorderRadius.circular(999),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: percent / 100,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                decoration: BoxDecoration(
                  color: Serene.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            usage == null
                ? 'Hesaplanıyor…'
                : '${fmtBytes(usage.used)} kullanılıyor / ${fmtBytes(usage.total)} toplam alan',
            style: body(11, color: Serene.secondary, height: 1.3),
          ),
        ],
      ),
    );
  }
}

/// Spike'a ozel: ornek veriyle tum kart durumlarini gormek icin.
class _DemoSwitch extends StatelessWidget {
  const _DemoSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return HoverSurface(
      onTap: () => onChanged(!value),
      background: Colors.transparent,
      hoverBackground: Serene.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: value ? Serene.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: value ? Serene.primary : Serene.outline,
              ),
            ),
            child: value
                ? Center(
                    child: SIcon('check', size: 11, color: Serene.onPrimary),
                  )
                : null,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Örnek veriyle göster',
              style: body(11, color: Serene.secondary),
            ),
          ),
        ],
      ),
    );
  }
}
