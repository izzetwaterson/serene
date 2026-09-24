import 'dart:convert';
import 'dart:io';

/// %APPDATA%\Serene altindaki durum dosyalari.
class SerenePaths {
  static String get appData {
    final roaming = Platform.environment['APPDATA'];
    if (roaming != null && roaming.isNotEmpty) return roaming;
    return Directory.current.path;
  }

  static String get tasks => '$appData\\Serene\\tasks.json';
  static String get captures => '$appData\\Serene\\captures.json';
  static String get settings => '$appData\\Serene\\settings.json';
  static String get ipc => '$appData\\Serene\\ipc.json';
}

/// Rust tarafindaki DownloadMeta ile ayni alanlar (snake_case).
class Task {
  Task({
    required this.id,
    required this.url,
    required this.filename,
    required this.dest,
    required this.total,
    required this.downloaded,
    required this.speed,
    required this.status,
    required this.category,
    required this.createdAt,
    this.error,
    this.finishedAt,
    this.kind = 'file',
    this.source,
    this.pending = false,
    this.resumable = false,
  });

  final String id;
  final String url;
  final String filename;
  final String dest;
  final int total;
  final String category;
  final int createdAt;
  final String kind;
  final String? source;
  final bool resumable;

  /// Durum alanlari spike icin yerinde degistirilebilir: ornek veri
  /// duraklatilip devam ettirilebilsin. Gercek gorevler diskten okunur.
  int downloaded;
  String status;
  double speed;
  String? error;
  int? finishedAt;

  /// Onay bekleyen gorevler duraklatilmis dogar; ayri tutulur ki demo
  /// gorevlerde de yerinde degistirilebilsin.
  bool pending;

  String get dir {
    final cut = dest.lastIndexOf(RegExp(r'[\\/]'));
    return cut > 0 ? dest.substring(0, cut) : dest;
  }

  static Task fromJson(Map<String, dynamic> raw) => Task(
        id: raw['id'] as String? ?? '',
        url: raw['url'] as String? ?? '',
        filename: raw['filename'] as String? ?? '',
        dest: raw['dest'] as String? ?? '',
        total: (raw['total'] as num?)?.toInt() ?? 0,
        downloaded: (raw['downloaded'] as num?)?.toInt() ?? 0,
        speed: (raw['speed'] as num?)?.toDouble() ?? 0,
        status: raw['status'] as String? ?? 'queued',
        category: raw['category'] as String? ?? 'other',
        createdAt: (raw['created_at'] as num?)?.toInt() ?? 0,
        error: raw['error'] as String?,
        finishedAt: (raw['finished_at'] as num?)?.toInt(),
        kind: raw['kind'] as String? ?? 'file',
        source: raw['source'] as String?,
        pending: raw['pending'] as bool? ?? false,
        resumable: raw['resumable'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'filename': filename,
        'dest': dest,
        'total': total,
        'downloaded': downloaded,
        'speed': speed,
        'status': status,
        'category': category,
        'created_at': createdAt,
        if (error != null) 'error': error,
        if (finishedAt != null) 'finished_at': finishedAt,
        'kind': kind,
        if (source != null) 'source': source,
        'pending': pending,
        'resumable': resumable,
      };
}

/// Eklentinin yakaladigi medya adayi (kayit bicimi camelCase).
class CaptureItem {
  CaptureItem({
    required this.id,
    required this.url,
    required this.filename,
    required this.size,
    required this.contentType,
    required this.kind,
    required this.site,
    required this.createdAt,
  });

  final String id;
  final String url;
  final String filename;
  final int size;
  final String contentType;
  final String kind;
  final String site;
  final int createdAt;

  static CaptureItem fromJson(Map<String, dynamic> raw) => CaptureItem(
        id: raw['id'] as String? ?? '',
        url: raw['url'] as String? ?? '',
        filename: raw['filename'] as String? ?? '',
        size: (raw['size'] as num?)?.toInt() ?? 0,
        contentType: raw['contentType'] as String? ?? '',
        kind: raw['kind'] as String? ?? 'file',
        site: raw['site'] as String? ?? '',
        createdAt: (raw['createdAt'] as num?)?.toInt() ?? 0,
      );
}

class Settings {
  Settings({required this.downloadDir, required this.confirmBrowserDownload});

  final String downloadDir;
  final bool confirmBrowserDownload;

  static Settings load() {
    final fallback = Settings(
      downloadDir: '${Platform.environment['USERPROFILE'] ?? ''}\\Downloads',
      confirmBrowserDownload: true,
    );
    try {
      final raw = readJson(SerenePaths.settings);
      if (raw is! Map<String, dynamic>) return fallback;
      return Settings(
        downloadDir: raw['downloadDir'] as String? ?? fallback.downloadDir,
        confirmBrowserDownload: raw['confirmBrowserDownload'] as bool? ?? true,
      );
    } catch (_) {
      return fallback;
    }
  }
}

List<Map<String, dynamic>> readJsonList(String path) {
  try {
    final raw = readJson(path);
    if (raw is! List) return const [];
    return raw.whereType<Map<String, dynamic>>().toList();
  } catch (_) {
    return const [];
  }
}

dynamic readJson(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  return jsonDecode(file.readAsStringSync());
}

/// Gercek gorevleri diskten okur.
List<Task> loadTasks() =>
    readJsonList(SerenePaths.tasks).map(Task.fromJson).toList();

List<CaptureItem> loadCaptures() =>
    readJsonList(SerenePaths.captures).map(CaptureItem.fromJson).toList();
