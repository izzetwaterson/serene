import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'cards.dart';
import 'data.dart';
import 'demo.dart';
import 'format.dart';
import 'theme.dart';
import 'widgets.dart';

/// Ana pencere: Tauri arayuzunun Flutter karsiligi.
class MainWindow extends StatefulWidget {
  const MainWindow({super.key, this.demoOn = false});

  final bool demoOn;

  @override
  State<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends State<MainWindow> with WindowListener {
  List<Task> _real = [];
  final List<Task> _demo = demoTasks();
  List<CaptureItem> _captures = [];
  final Settings _settings = Settings.load();

  String _filter = 'all';
  String? _category;
  String _view = 'tasks';
  String _query = '';

  bool _demoOn = false;
  bool _bridgeUp = false;
  bool _maximized = false;
  DiskUsage? _disk;
  String? _notice;

  final TextEditingController _search = TextEditingController();
  final TextEditingController _url = TextEditingController();

  Timer? _clock;
  Timer? _noticeTimer;
  bool _ticking = false;

  List<Task> get _tasks => _demoOn ? [..._demo, ..._real] : _real;

  @override
  void initState() {
    super.initState();
    _demoOn = widget.demoOn;
    windowManager.addListener(this);
    _reload();
    _checkBridge();
    _loadDisk();
    _clock = Timer.periodic(const Duration(milliseconds: 200), (_) => _tick());
  }

  @override
  void dispose() {
    _clock?.cancel();
    _noticeTimer?.cancel();
    windowManager.removeListener(this);
    _search.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  void _reload() {
    final tasks = loadTasks();
    final captures = loadCaptures();
    if (!mounted) return;
    setState(() {
      _real = tasks;
      _captures = captures;
    });
  }

  void _tick() {
    /* Dosya okuma ve yeniden cizim ayni karede ust uste binmesin. */
    if (_ticking) return;
    _ticking = true;
    try {
      if (_demoOn) tickDemoTasks(_demo, 0.2);
      _reload();
    } finally {
      _ticking = false;
    }
  }

  Future<void> _checkBridge() async {
    var up = false;
    try {
      final raw = readJson(SerenePaths.ipc);
      if (raw is Map<String, dynamic>) {
        final port = (raw['port'] as num?)?.toInt();
        if (port != null) {
          final socket = await Socket.connect('127.0.0.1', port,
              timeout: const Duration(milliseconds: 400));
          socket.destroy();
          up = true;
        }
      }
    } catch (_) {
      up = false;
    }
    if (!mounted) return;
    setState(() => _bridgeUp = up);
  }

  Future<void> _loadDisk() async {
    final drive = RegExp(r'^([A-Za-z]:)').firstMatch(_settings.downloadDir)?.group(1) ?? 'C:';
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        'Get-CimInstance Win32_LogicalDisk -Filter "DeviceID=\'$drive\'" | '
            'Select-Object Size,FreeSpace | ConvertTo-Json -Compress',
      ], runInShell: false);
      final raw = jsonDecode((result.stdout as String).trim()) as Map<String, dynamic>;
      final total = (raw['Size'] as num?)?.toInt() ?? 0;
      final free = (raw['FreeSpace'] as num?)?.toInt() ?? 0;
      if (total == 0) return;
      if (!mounted) return;
      setState(() {
        _disk = DiskUsage(mount: drive, total: total, free: free, used: total - free);
      });
    } catch (_) {
      /* disk bilgisi alinamazsa kart bos kalir */
    }
  }

  void _notify(String message) {
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

  void _runAction(Task task, String action) {
    final live = _mutable(task.id);
    if (live == null) {
      _notify('Spike: indirme motoru bagli degil — ${task.filename}');
      return;
    }

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
        case 'info':
          _openHandoff(live);
        default:
          _notify('Spike: "$action" islemi motora baglanmayi bekliyor');
      }
    });
  }

  void _openHandoff(Task task) {
    final payload = base64Url.encode(utf8.encode(jsonEncode(task.toJson())));
    Process.start(Platform.resolvedExecutable, ['--handoff=$payload'],
        mode: ProcessStartMode.detached);
  }

  void _submitUrl() {
    final value = _url.text.trim();
    if (value.isEmpty) return;
    _url.clear();
    _notify('Spike: indirme motoru bagli degil — "$value" baslatilamadi');
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
                onSettings: () => _notify('Spike: ayarlar penceresi henuz yok'),
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
                                ? _notify('Spike: baglanti alanina bir adres yapistirin')
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
                            onCaptures: () => setState(() => _view = 'captures'),
                            onDemo: (value) => setState(() => _demoOn = value),
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            child: _view == 'captures'
                                ? CapturesPane(
                                    items: _captures,
                                    notice: _notice,
                                    onNotice: _notify,
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
                                    onNotice: _notify,
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
        decoration: const BoxDecoration(
          color: Serene.background,
          border: Border(bottom: BorderSide(color: Color(0x80DCD8CE))),
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
              child: const Center(child: SIcon('spa', size: 15, color: Serene.primary)),
            ),
            const SizedBox(width: 12),
            Text('Serene',
                style: head(15, weight: FontWeight.w500, letterSpacing: -0.3)),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Serene.surfaceContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text('v0.1', style: body(11, weight: FontWeight.w500, color: Serene.secondary)),
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
              border: const Color(0x99DCD8CE),
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
                  border: Border.all(color: const Color(0x333D6A4B)),
                ),
                child: Center(
                  child: Text('EF',
                      style: body(12, weight: FontWeight.w600, color: Serene.primary)),
                ),
              ),
            ),
            const SizedBox(width: 20),
            Container(
              padding: const EdgeInsets.only(left: 8),
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: Color(0x99DCD8CE))),
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
                    border: const Color(0x99DCD8CE),
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
                    border: const Color(0x99DCD8CE),
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
                    border: const Color(0x99DCD8CE),
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
        border: Border.all(color: const Color(0x99DCD8CE)),
      ),
      child: Row(
        children: [
          const SIcon('search', size: 17, color: Serene.outline),
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
                hintStyle: body(13, color: Serene.outline.withValues(alpha: 0.8)),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Serene.surfaceContainer,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0x99DCD8CE)),
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
        border: Border.all(color: const Color(0x99DCD8CE)),
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

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
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
        decoration: const BoxDecoration(color: Serene.primary, shape: BoxShape.circle),
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
              hoverBackground: const Color(0xF23D6A4B),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SIcon('add_circle', size: 19, color: Serene.onPrimary),
                  const SizedBox(width: 10),
                  Text('Yeni İndirme Başlat',
                      style: body(14, weight: FontWeight.w500, color: Serene.onPrimary)),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Serene.surfaceContainerLow,
                borderRadius: BorderRadius.circular(Serene.radiusCard),
                border: Border.all(color: const Color(0x80DCD8CE)),
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
                      active: view == 'tasks' && category == null && filter == key,
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
                    color: const Color(0x80DCD8CE),
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
          style: body(11,
              weight: FontWeight.w600, color: Serene.outline, letterSpacing: 0.6),
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
          SIcon(icon, size: compact ? 17 : 18, color: active ? Serene.primary : Serene.secondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: body(compact ? 13 : 13.5,
                  weight: active ? FontWeight.w500 : FontWeight.w400, color: tone),
            ),
          ),
          Text(
            '$count',
            style: mono(compact ? 11 : 12,
                weight: FontWeight.w600,
                color: active ? Serene.primary : Serene.outline),
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
        border: Border.all(color: const Color(0x66DCD8CE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SIcon('hard_drive', size: 15, color: Serene.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  usage == null ? 'Disk' : '${usage.mount} sürücüsü',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: body(12,
                      weight: FontWeight.w500, color: Serene.onSecondaryContainer),
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
              border: Border.all(color: value ? Serene.primary : Serene.outline),
            ),
            child: value
                ? const Center(child: SIcon('check', size: 11, color: Serene.onPrimary))
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
