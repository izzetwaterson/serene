import 'package:flutter/material.dart';

import 'data.dart';
import 'theme.dart';

/// app.js icindeki bicimlendirme yardimcilari.

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
  if (seconds < 60) return '${seconds.round()} sn';
  if (seconds < 3600) {
    return '${(seconds ~/ 60)} dk ${(seconds % 60).round()} sn';
  }
  return '${(seconds ~/ 3600)} sa ${((seconds % 3600) ~/ 60)} dk';
}

const _months = [
  'Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz',
  'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara',
];

String fmtWhen(int? unixSeconds) {
  if (unixSeconds == null || unixSeconds == 0) return '';
  final then = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  final now = DateTime.now();
  final startOfToday = DateTime(now.year, now.month, now.day);
  final startOfThen = DateTime(then.year, then.month, then.day);
  final dayDiff = startOfToday.difference(startOfThen).inDays;
  final clock = '${then.hour.toString().padLeft(2, '0')}:'
      '${then.minute.toString().padLeft(2, '0')}';

  if (dayDiff == 0) return 'Bugün, $clock';
  if (dayDiff == 1) return 'Dün, $clock';
  if (then.year == now.year) return '${then.day} ${_months[then.month - 1]}, $clock';
  return '${then.day} ${_months[then.month - 1]} ${then.year}, $clock';
}

double percentOf(Task task) {
  if (task.status == 'completed') return 100;
  if (task.total == 0) return 0;
  return (task.downloaded / task.total * 100).clamp(0, 100);
}

/// app.js metaLine ile ayni metin.
String metaLine(Task task) {
  if (task.pending) {
    final size = task.total > 0 ? fmtBytes(task.total) : 'Boyut bilinmiyor';
    return '$size • Onay bekliyor';
  }
  switch (task.status) {
    case 'completed':
      return '${fmtBytes(task.total)} • ${fmtWhen(task.finishedAt)}';
    case 'failed':
      final message = task.error;
      return (message == null || message.isEmpty) ? 'Bilinmeyen hata' : message;
    case 'queued':
      final size = task.total > 0 ? '${fmtBytes(task.total)} • ' : '';
      return '${size}Kuyrukta bekliyor';
    case 'paused':
      return '${fmtBytes(task.downloaded)} / ${fmtBytes(task.total)} • Duraklatıldı';
  }

  final parts = [
    '${fmtBytes(task.downloaded)} / ${fmtBytes(task.total)}',
    fmtSpeed(task.speed),
  ];
  if (task.total > 0 && task.speed > 0) {
    final eta = fmtEta((task.total - task.downloaded) / task.speed);
    if (eta != null) parts.add('Kalan süre: $eta');
  } else if (task.total == 0) {
    parts.add('Boyut bilinmiyor');
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

const _categoryStyles = <String, CategoryStyle>{
  'video': CategoryStyle('movie', Color(0x66D3EBD8), Serene.primary),
  'audio': CategoryStyle('music_note', Color(0x66D3EBD8), Serene.primary),
  'image': CategoryStyle('image', Color(0x66F8E0A8), Serene.tertiary),
  'document': CategoryStyle('description', Serene.surfaceContainerHigh, Serene.primary),
  'software': CategoryStyle('code', Color(0x66D3EBD8), Serene.primary),
  'archive': CategoryStyle('folder_zip', Color(0x66F8E0A8), Serene.tertiary),
  'other': CategoryStyle('draft', Serene.surfaceContainerHigh, Serene.secondary),
};

CategoryStyle styleOf(Task task) =>
    _categoryStyles[task.category] ?? _categoryStyles['other']!;

const inProgress = {'downloading', 'paused'};

const filterTitles = <String, String>{
  'all': 'Tüm İndirmeler',
  'active': 'Devam Edenler',
  'completed': 'Tamamlananlar',
  'queued': 'Kuyrukta',
  'failed': 'Hata Verenler',
};

const categoryTitles = <String, String>{
  'video': 'Videolar',
  'audio': 'Sesler',
  'image': 'Görseller',
  'document': 'Belgeler',
  'software': 'Yazılımlar',
  'archive': 'Sıkıştırılmış',
  'other': 'Diğer',
};

/// Durum rozetinin etiketi ve renkleri (statusChip).
({String label, Color bg, Color fg}) statusChip(Task task) {
  if (task.pending) {
    return (
      label: 'Onay bekliyor',
      bg: const Color(0x80F8E0A8),
      fg: Serene.onTertiaryContainer,
    );
  }
  switch (task.status) {
    case 'downloading':
      return (
        label: 'Devam ediyor',
        bg: const Color(0x80D3EBD8),
        fg: Serene.onPrimaryFixed,
      );
    case 'paused':
      return (label: 'Duraklatıldı', bg: Serene.surfaceContainer, fg: Serene.secondary);
    case 'failed':
      return (
        label: 'Hata',
        bg: const Color(0xB3FCE4E2),
        fg: Serene.onErrorContainer,
      );
    case 'completed':
      return (
        label: 'Tamamlandı',
        bg: const Color(0x80D3EBD8),
        fg: Serene.onPrimaryFixed,
      );
  }
  return (
    label: 'Kuyrukta',
    bg: const Color(0x80F8E0A8),
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
      return const [
        TaskAction('pause', 'pause', 'Duraklat', 0),
        TaskAction('remove', 'close', 'İptal Et', 1),
      ];
    case 'paused':
      return [
        if (task.pending) const TaskAction('info', 'info', 'Bilgileri Aç', 2),
        const TaskAction('resume', 'play_arrow', 'Devam Et', 2),
        const TaskAction('remove', 'close', 'İptal Et', 1),
      ];
    case 'queued':
      return const [TaskAction('remove', 'close', 'Kuyruktan Çıkar', 1)];
    case 'failed':
      return const [
        TaskAction('retry', 'refresh', 'Yeniden Dene', 2),
        TaskAction('remove', 'close', 'Kaldır', 1),
      ];
    case 'completed':
      return const [
        TaskAction('open', 'open_in_new', 'Dosyayı Aç', 0),
        TaskAction('reveal', 'folder_open', 'Klasörde Göster', 0),
        TaskAction('remove', 'delete', 'Kaldır', 1),
      ];
  }
  return const [];
}

/// "Tarayıcıdan" panelindeki tur etiketi.
String captureKindLabel(String kind) => switch (kind) {
      'hls' => 'HLS',
      'dash' => 'DASH',
      _ => 'Dosya',
    };

CategoryStyle captureKindStyle(String kind, String contentType) {
  if (kind == 'hls' || kind == 'dash') {
    return const CategoryStyle('movie', Color(0x66F8E0A8), Serene.tertiary);
  }
  if (contentType.startsWith('image/')) return _categoryStyles['image']!;
  if (contentType.startsWith('audio/')) return _categoryStyles['audio']!;
  if (contentType.startsWith('video/')) return _categoryStyles['video']!;
  if (contentType.contains('pdf') || contentType.startsWith('text/')) {
    return _categoryStyles['document']!;
  }
  return _categoryStyles['other']!;
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
  return site.isNotEmpty ? site : 'Medya';
}
