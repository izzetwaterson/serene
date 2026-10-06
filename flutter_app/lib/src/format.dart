import 'package:flutter/material.dart';

import 'data.dart';
import 'strings.dart';
import 'theme.dart';

/// app.js icindeki bicimlendirme yardimcilari. Metinler `T`den okunur:
/// bicimlendirme cagri aninda yapildigi icin dil degisince cikti da degisir.

const _units = ['B', 'KB', 'MB', 'GB', 'TB'];

String fmtBytes(num bytes) {
  if (bytes <= 0) return '0 B';
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < _units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final digits = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${_units[unit]}';
}

String fmtSpeed(double bytesPerSecond) {
  if (bytesPerSecond <= 0) return '—';
  return '${fmtBytes(bytesPerSecond)}/s';
}

String? fmtEta(double seconds) {
  if (!seconds.isFinite || seconds <= 0) return null;
  if (seconds < 60) return '${seconds.round()} ${T.unitSeconds}';
  if (seconds < 3600) {
    return '${(seconds ~/ 60)} ${T.unitMinutes} '
        '${(seconds % 60).round()} ${T.unitSeconds}';
  }
  return '${(seconds ~/ 3600)} ${T.unitHours} '
      '${((seconds % 3600) ~/ 60)} ${T.unitMinutes}';
}

String fmtWhen(int? unixSeconds) {
  if (unixSeconds == null || unixSeconds == 0) return '';
  final then = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  final now = DateTime.now();
  final startOfToday = DateTime(now.year, now.month, now.day);
  final startOfThen = DateTime(then.year, then.month, then.day);
  final dayDiff = startOfToday.difference(startOfThen).inDays;
  final clock = '${then.hour.toString().padLeft(2, '0')}:'
      '${then.minute.toString().padLeft(2, '0')}';
  final month = T.shortMonths[then.month - 1];

  if (dayDiff == 0) return '${T.today}, $clock';
  if (dayDiff == 1) return '${T.yesterday}, $clock';
  if (then.year == now.year) return T.dateLine(then.day, month, null, clock);
  return T.dateLine(then.day, month, then.year, clock);
}

double percentOf(Task task) {
  if (task.status == 'completed') return 100;
  if (task.total == 0) return 0;
  return (task.downloaded / task.total * 100).clamp(0, 100);
}

/// Motorun `u64::MAX` isareti; FRB'de `i64::MAX`'e kirpilir ve "boyut
/// bilinmiyor" anlamina gelir.
const int unknownSegmentEnd = 9223372036854775807;

/// Bir baglanti parcasinin doluluk orani (0..1).
///
/// Parca boyutu bilinmiyorsa (HLS/DASH ya da tek akis) yalnizca "bayt alindi
/// mi" bilgisi kullanilir.
double segmentRatio(UiSegment part) {
  if (part.end <= part.start || part.end >= unknownSegmentEnd) {
    return part.downloaded > 0 ? 1 : 0;
  }
  final size = part.end - part.start + 1;
  if (size <= 0) return 0;
  return (part.downloaded / size).clamp(0, 1).toDouble();
}

/// app.js metaLine ile ayni metin.
String metaLine(Task task) {
  if (task.pending) {
    final size = task.total > 0 ? fmtBytes(task.total) : T.unknownSize;
    return '$size • ${T.statusPendingConfirm}';
  }
  switch (task.status) {
    case 'completed':
      return '${fmtBytes(task.total)} • ${fmtWhen(task.finishedAt)}';
    case 'failed':
      final message = task.error;
      return (message == null || message.isEmpty) ? T.unknownError : message;
    case 'queued':
      final size = task.total > 0 ? '${fmtBytes(task.total)} • ' : '';
      return '$size${T.queuedWaiting}';
    case 'paused':
      return '${fmtBytes(task.downloaded)} / ${fmtBytes(task.total)} • '
          '${T.statusPaused}';
  }

  final parts = [
    '${fmtBytes(task.downloaded)} / ${fmtBytes(task.total)}',
    fmtSpeed(task.speed),
  ];
  if (task.total > 0 && task.speed > 0) {
    final eta = fmtEta((task.total - task.downloaded) / task.speed);
    if (eta != null) parts.add(T.timeLeft(eta));
  } else if (task.total == 0) {
    parts.add(T.unknownSize);
  }
  return parts.join(' • ');
}

/// Kategori ikonu ve renkleri (CATEGORY_STYLE).
class CategoryStyle {
  const CategoryStyle(this.icon, this.box, this.tone);

  final String icon;
  final Color box;
  final Color tone;
}

/// Renkler cagri aninda paletten okunur; harita sabit olamaz, cunku tema
/// degisince kategori renkleri de degisir.
Map<String, CategoryStyle> _categoryStyles() => {
  'video': CategoryStyle('movie', Serene.tintPrimary, Serene.primary),
  'audio': CategoryStyle('music_note', Serene.tintPrimary, Serene.primary),
  'image': CategoryStyle('image', Serene.tintTertiary, Serene.tertiary),
  'document': CategoryStyle('description', Serene.surfaceContainerHigh, Serene.primary),
  'software': CategoryStyle('code', Serene.tintPrimary, Serene.primary),
  'archive': CategoryStyle('folder_zip', Serene.tintTertiary, Serene.tertiary),
  'other': CategoryStyle('draft', Serene.surfaceContainerHigh, Serene.secondary),
};

CategoryStyle styleOf(Task task) {
  final styles = _categoryStyles();
  return styles[task.category] ?? styles['other']!;
}

const inProgress = {'downloading', 'paused'};

/// Filtre ve kategori basliklari cagri aninda `T`den okunur.
Map<String, String> get filterTitles => T.filterTitles;

Map<String, String> get categoryTitles => T.categoryTitles;

/// Durum rozetinin etiketi ve renkleri (statusChip).
({String label, Color bg, Color fg}) statusChip(Task task) {
  if (task.pending) {
    return (
      label: T.statusPendingConfirm,
      bg: Serene.tintTertiaryStrong,
      fg: Serene.onTertiaryContainer,
    );
  }
  switch (task.status) {
    case 'downloading':
      return (
        label: T.statusDownloading,
        bg: Serene.tintPrimaryStrong,
        fg: Serene.onPrimaryFixed,
      );
    case 'paused':
      return (
        label: T.statusPaused,
        bg: Serene.surfaceContainer,
        fg: Serene.secondary,
      );
    case 'failed':
      return (
        label: T.statusError,
        bg: Serene.tintError,
        fg: Serene.onErrorContainer,
      );
    case 'completed':
      return (
        label: T.statusCompleted,
        bg: Serene.tintPrimaryStrong,
        fg: Serene.onPrimaryFixed,
      );
  }
  return (
    label: T.statusQueued,
    bg: Serene.tintTertiaryStrong,
    fg: Serene.onTertiaryContainer,
  );
}

Color barTone(Task task) {
  switch (task.status) {
    case 'failed':
      return Serene.error.withValues(alpha: 0.7);
    case 'paused':
      return Serene.primary.withValues(alpha: 0.45);
    case 'completed':
      return Serene.primary.withValues(alpha: 0.6);
  }
  return Serene.primary;
}

/// app.js actionsFor — kart uzerindeki dugmeler.
class TaskAction {
  const TaskAction(this.action, this.icon, this.title, this.tone);

  final String action;
  final String icon;
  final String title;

  /// 0 notr, 1 tehlike, 2 birincil
  final int tone;
}

List<TaskAction> actionsFor(Task task) {
  switch (task.status) {
    case 'downloading':
      return [
        TaskAction('pause', 'pause', T.actionPause, 0),
        TaskAction('remove', 'close', T.actionCancel, 1),
      ];
    case 'paused':
      return [
        if (task.pending) TaskAction('info', 'info', T.actionDetails, 2),
        TaskAction('resume', 'play_arrow', T.actionResume, 2),
        TaskAction('remove', 'close', T.actionCancel, 1),
      ];
    case 'queued':
      return [TaskAction('remove', 'close', T.actionDequeue, 1)];
    case 'failed':
      return [
        TaskAction('retry', 'refresh', T.actionRetry, 2),
        TaskAction('remove', 'close', T.actionRemove, 1),
      ];
    case 'completed':
      return [
        TaskAction('open', 'open_in_new', T.actionOpen, 0),
        TaskAction('reveal', 'folder_open', T.actionReveal, 0),
        TaskAction('remove', 'delete', T.actionRemove, 1),
      ];
  }
  return const [];
}

/// "Tarayıcıdan" panelindeki tur etiketi.
String captureKindLabel(String kind) => switch (kind) {
      'hls' => 'HLS',
      'dash' => 'DASH',
      _ => T.fileKind,
    };

CategoryStyle captureKindStyle(String kind, String contentType) {
  final styles = _categoryStyles();
  if (kind == 'hls' || kind == 'dash') {
    return CategoryStyle('movie', Serene.tintTertiary, Serene.tertiary);
  }
  if (contentType.startsWith('image/')) return styles['image']!;
  if (contentType.startsWith('audio/')) return styles['audio']!;
  if (contentType.startsWith('video/')) return styles['video']!;
  if (contentType.contains('pdf') || contentType.startsWith('text/')) {
    return styles['document']!;
  }
  return styles['other']!;
}

String captureName(CaptureItem item) {
  if (item.filename.trim().isNotEmpty) return item.filename.trim();

  final withoutQuery = item.url.split(RegExp(r'[?#]')).first;
  final segments = withoutQuery.split('/').where((part) => part.isNotEmpty);
  final last = segments.isEmpty ? '' : segments.last;
  var decoded = last;
  try {
    decoded = Uri.decodeComponent(last);
  } catch (_) {
    /* bozuk yuzde kodlamasi ham kalsin */
  }
  final trimmed = decoded.trim();
  if (trimmed.isNotEmpty) return trimmed;
  final site = item.site.trim();
  return site.isNotEmpty ? site : T.mediaKind;
}
