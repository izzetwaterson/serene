//! Durum dosyasi yazilamadiginda kullanici bunu ogrenmeli.
//!
//! `store::save_*` imzalari geriye donuk uyum icin sonuc dondurmuyor; hata
//! biriktiriliyor ve `manager` bunu `CoreEvent::StorageError` olarak
//! yayinliyor. Bu test o zincirin **tamamini** dener: yazma gercekten
//! basarisiz oluyor, hata toplanip yayinlaniyor.
//!
//! Diger yarisi (arayuzde gorunur olmasi) `flutter_app/test/widget_test.dart`
//! icindeki `StorageErrorBanner` testidir.

use std::time::Duration;

use serene_core::bus::{CoreEvent, EventBus};
use serene_core::manager::DownloadManager;
use serene_core::models::{Category, DownloadKind, DownloadMeta, Status};
use tokio::sync::broadcast::error::TryRecvError;

fn meta(id: &str, temp_dir: &str) -> DownloadMeta {
    DownloadMeta {
        id: id.into(),
        url: "https://ornek.dev/a.bin".into(),
        filename: "a.bin".into(),
        dest: String::new(),
        temp_dir: temp_dir.into(),
        total: 0,
        downloaded: 0,
        speed: 0.0,
        status: Status::Queued,
        error: None,
        category: Category::Other,
        resumable: false,
        segments: Vec::new(),
        created_at: 0,
        finished_at: None,
        etag: None,
        referer: None,
        cookie: None,
        user_agent: None,
        kind: DownloadKind::File,
        source: None,
        pending: false,
    }
}

/// `tasks.json` yerine bir klasor koyarak yazma adimini kasti olarak
/// basarisiz birakir. Windows'ta `rename` bir klasorun uzerine yazamaz; bu
/// makineye ozel bir numara yok, davranisin kendisi yeterli.
#[test]
fn yazma_basarisiz_olunca_kullaniciya_ulasiyor() {
    let dir = std::env::temp_dir().join(format!("serene-depo-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("tasks.json")).expect("gecici klasor");
    std::env::set_var("SERENE_DATA_DIR", &dir);

    let bus = EventBus::default();
    let mut events = bus.subscribe();
    let manager = DownloadManager::new(bus).expect("motor kurulmali");

    manager.insert(meta("kaydedilemeyen", &dir.join("gecici").to_string_lossy()));
    manager.persist_now();

    // Olay yayinlandi mi? Kanal bos olabilir, bu yuzden birkac kez denenir.
    let mut found = None;
    for _ in 0..20 {
        match events.try_recv() {
            Ok(CoreEvent::StorageError(message)) => {
                found = Some(message);
                break;
            }
            Ok(_) => continue,
            Err(TryRecvError::Empty) => std::thread::sleep(Duration::from_millis(25)),
            Err(e) => panic!("olay kanali beklenmedik durumda: {e}"),
        }
    }

    let message = found.expect("yazma hatasi kullaniciya ulasmadi");
    assert!(
        message.contains("tasks.json"),
        "uyari hangi dosyanin yazilamadigini soylemeli: {message}"
    );
    assert!(
        message.contains("yazilamadi"),
        "uyari sebebi soylemeli: {message}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// Yazma dogrusu calistiginda **yanlis** uyari cikmamali. Bu, bandin surekli
/// yanip sonmesini onler.
#[test]
fn yazma_basarisiz_olunca_uyari_yok() {
    let dir = std::env::temp_dir().join(format!("serene-depo-iyi-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("gecici klasor");
    std::env::set_var("SERENE_DATA_DIR", &dir);

    let bus = EventBus::default();
    let mut events = bus.subscribe();
    let manager = DownloadManager::new(bus).expect("motor kurulmali");

    manager.insert(meta("kaydedilen", &dir.join("gecici").to_string_lossy()));
    manager.persist_now();
    // `persist_now` yalnizca diske yazar; kanalin canli oldugunu gormek icin
    // ayrica tam liste yayini isteyoruz.
    manager.emit_full();

    // `Tasks` olayi gelmesi yazmanin basarili oldugunu gosterir.
    let mut storage_error = false;
    let mut tasks_seen = false;
    for _ in 0..20 {
        match events.try_recv() {
            Ok(CoreEvent::StorageError(_)) => storage_error = true,
            Ok(CoreEvent::Tasks(_)) => tasks_seen = true,
            Ok(_) => continue,
            Err(TryRecvError::Empty) => std::thread::sleep(Duration::from_millis(25)),
            Err(e) => panic!("olay kanali beklenmedik durumda: {e}"),
        }
        if tasks_seen {
            break;
        }
    }

    assert!(tasks_seen, "gorev listesi yayinlanmali");
    assert!(!storage_error, "yazma basariliyken uyari cikmamali");

    // Gercekten dosyaya yazildi mi?
    assert!(
        dir.join("tasks.json").is_file(),
        "gorev listesi diske yazilmali"
    );

    let _ = std::fs::remove_dir_all(&dir);
}
