import 'data.dart';

/// Spike icin ornek gorevler. Gercek tasks.json'a hicbir sey yazilmaz;
/// bu gorevler yalnizca arayuzu dolu gormek icin bellege eklenir.
List<Task> demoTasks() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  const mb = 1024 * 1024;

  return [
    Task(
      id: 'demo-1',
      url: 'https://cdn.ornek.net/belgesel/bahar-manzarasi-4k.mp4',
      filename: 'Bahar Manzarası 4K - Doğa Belgeseli.mp4',
      dest: 'C:\\Users\\izzet\\Downloads\\Bahar Manzarası 4K - Doğa Belgeseli.mp4',
      total: 1450 * mb,
      downloaded: (1450 * mb * 0.38).round(),
      speed: 2.4 * mb,
      status: 'downloading',
      category: 'video',
      createdAt: now - 90,
      source: 'ui',
      resumable: true,
    ),
    Task(
      id: 'demo-2',
      url: 'https://surum.serene.app/Serene-Kurulum-0.1.0.exe',
      filename: 'Serene-Kurulum-0.1.0.exe',
      dest: 'C:\\Users\\izzet\\Downloads\\Serene-Kurulum-0.1.0.exe',
      total: 24 * mb,
      downloaded: (24 * mb * 0.71).round(),
      speed: 1.1 * mb,
      status: 'downloading',
      category: 'software',
      createdAt: now - 40,
      source: 'capture',
      resumable: true,
    ),
    Task(
      id: 'demo-3',
      url: 'https://cdn.ornek.net/muzik/nightingale.mp3',
      filename: 'Nightingale - Florence.mp3',
      dest: 'C:\\Users\\izzet\\Downloads\\Nightingale - Florence.mp3',
      total: 10 * mb,
      downloaded: (10 * mb * 0.22).round(),
      speed: 0,
      status: 'paused',
      category: 'audio',
      createdAt: now - 3600,
      resumable: true,
    ),
    Task(
      id: 'demo-4',
      url: 'https://cdn.ornek.net/dizi/kayip-arsivler-s02e04.mkv',
      filename: 'Kayıp Arşivler S02E04.mkv',
      dest: 'C:\\Users\\izzet\\Downloads\\Kayıp Arşivler S02E04.mkv',
      total: 890 * mb,
      downloaded: 0,
      speed: 0,
      status: 'paused',
      category: 'video',
      createdAt: now - 300,
      source: 'capture',
      pending: true,
      resumable: true,
    ),
    Task(
      id: 'demo-5',
      url: 'https://cdn.ornek.net/belge/tasarim-rehberi-2026.pdf',
      filename: 'Tasarım Rehberi 2026.pdf',
      dest: 'C:\\Users\\izzet\\Downloads\\Tasarım Rehberi 2026.pdf',
      total: 14 * mb,
      downloaded: 0,
      speed: 0,
      status: 'queued',
      category: 'document',
      createdAt: now - 200,
      resumable: true,
    ),
    Task(
      id: 'demo-6',
      url: 'https://cdn.ornek.net/yedek/site-yedegi-2026.zip',
      filename: 'site-yedegi-2026.zip',
      dest: 'C:\\Users\\izzet\\Downloads\\site-yedegi-2026.zip',
      total: 0,
      downloaded: 0,
      speed: 0,
      status: 'failed',
      category: 'archive',
      createdAt: now - 7200,
      error: 'Bağlantı zaman aşımına uğradı',
    ),
    Task(
      id: 'demo-7',
      url: 'https://cdn.ornek.net/gorsel/ekran-goruntusu.png',
      filename: 'Ekran Görüntüsü 2026-09-24.png',
      dest: 'C:\\Users\\izzet\\Downloads\\Ekran Görüntüsü 2026-09-24.png',
      total: (1258291),
      downloaded: (1258291),
      speed: 0,
      status: 'completed',
      category: 'image',
      createdAt: now - 5400,
      finishedAt: now - 5300,
    ),
  ];
}

/// Ilerleyen demo gorevlerini bir adim yurutur; bitenler tamamlanir.
void tickDemoTasks(List<Task> tasks, double seconds) {
  for (final task in tasks) {
    if (task.status != 'downloading') continue;

    final step = task.speed * seconds;
    if (step >= task.total - task.downloaded) {
      task.downloaded = task.total;
      task.status = 'completed';
      task.speed = 0;
      task.finishedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      continue;
    }

    task.downloaded += step.round();
  }
}
