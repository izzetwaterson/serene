import 'rust/api/dto.dart' as engine;

/// Arayuzin gordugu gorev kaydi.
///
/// Alanlar motorun FRB karsiligiyla ayni adlari tasir; tek fark durum,
/// kategori ve tur Dart enumlari yerine eski web arayuzunun kullandigi
/// kucuk harfli etiketlerle (`'downloading'`) saklanir. Boylece bicimlendirme
/// yardimcilari `app.js` ile birebir ayni kalir.
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

  /// Durum alanlari yerinde degistirilebilir: demo gorevler duraklatilip
  /// devam ettirilebilsin ve ilerleme paketleri yeni liste okumadan islenebilsin.
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

  /// Motorun FRB karsiligidan arayuz kaydi uretir.
  ///
  /// `PlatformInt64` masaustunde `int`, webde `BigInt`'tir; `toInt()` ile
  /// ikisinde de ayni okunur.
  static Task fromEngine(engine.Task raw) => Task(
    id: raw.id,
    url: raw.url,
    filename: raw.filename,
    dest: raw.dest,
    total: raw.total.toInt(),
    downloaded: raw.downloaded.toInt(),
    speed: raw.speed,
    status: raw.status.name,
    category: raw.category.name,
    createdAt: raw.createdAt.toInt(),
    error: raw.error,
    finishedAt: raw.finishedAt?.toInt(),
    kind: raw.kind.name,
    source: raw.source,
    pending: raw.pending,
    resumable: raw.resumable,
  );

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

  static CaptureItem fromEngine(engine.Capture raw) => CaptureItem(
    id: raw.id,
    url: raw.url,
    filename: raw.filename,
    size: raw.size.toInt(),
    contentType: raw.contentType,
    kind: raw.kind.name,
    site: raw.site,
    createdAt: raw.createdAt.toInt(),
  );
}

class Settings {
  Settings({
    required this.downloadDir,
    required this.maxConcurrent,
    required this.connections,
    required this.watchClipboard,
    required this.closeToTray,
    required this.confirmBrowserDownload,
  });

  static Settings fromEngine(engine.AppConfig raw) => Settings(
    downloadDir: raw.downloadDir,
    maxConcurrent: raw.maxConcurrent,
    connections: raw.connections,
    watchClipboard: raw.watchClipboard,
    closeToTray: raw.closeToTray,
    confirmBrowserDownload: raw.confirmBrowserDownload,
  );

  final String downloadDir;
  final int maxConcurrent;
  final int connections;
  final bool watchClipboard;
  final bool closeToTray;
  final bool confirmBrowserDownload;
}
