use std::fs;
use std::path::{Path, PathBuf};

use crate::models::{CaptureItem, DownloadMeta, Settings, Status};

/// JSON durumunu atomik olarak (gecici dosya + rename) diske yazar.
pub fn write_json<T: serde::Serialize>(path: &Path, value: &T) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let payload = serde_json::to_vec_pretty(value)?;
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, &payload)?;
    if path.exists() {
        let _ = fs::remove_file(path);
    }
    fs::rename(&tmp, path)?;
    Ok(())
}

pub fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Option<T> {
    let raw = fs::read(path).ok()?;
    serde_json::from_slice(&raw).ok()
}

pub fn load_tasks(path: &Path) -> Vec<DownloadMeta> {
    let mut tasks: Vec<DownloadMeta> = read_json(path).unwrap_or_default();
    // Onceki oturumda yarim kalan isler kuyruga alinir; parcalar diskte durdugu
    // icin kaldigi yerden devam eder.
    for task in tasks.iter_mut() {
        match task.status {
            Status::Downloading | Status::Queued => {
                task.status = Status::Paused;
                task.speed = 0.0;
            }
            Status::Failed => task.speed = 0.0,
            _ => {}
        }
    }
    tasks
}

pub fn save_tasks(path: &Path, tasks: &[DownloadMeta]) {
    let _ = write_json(path, &tasks);
}

pub fn load_captures(path: &Path) -> Vec<CaptureItem> {
    read_json(path).unwrap_or_default()
}

pub fn save_captures(path: &Path, items: &[CaptureItem]) {
    let _ = write_json(path, &items);
}

/// Listeye url bazinda ekler. Ayni adres tekrar bildirilirse mevcut kayit ve
/// id'si korunur; yeni kayit eklendiyse `true` doner (en yeni kayit basta).
pub fn upsert_capture(items: &mut Vec<CaptureItem>, item: CaptureItem) -> (CaptureItem, bool) {
    if let Some(existing) = items.iter().find(|c| c.url == item.url) {
        return (existing.clone(), false);
    }
    items.insert(0, item.clone());
    (item, true)
}

pub fn load_settings(path: &Path) -> Settings {
    read_json(path).unwrap_or_default()
}

pub fn save_settings(path: &Path, settings: &Settings) {
    let _ = write_json(path, settings);
}

/// Kullanici verisi klasoru (kalici gorev listesi + ayarlar + kopru kaydi).
///
/// `SERENE_DATA_DIR` verildiginde orasi kullanilir: kosumlar ve birim testleri
/// gercek listede indirme baslatmadan yaliniz bir motor kurabilsin diye.
/// Tarayici host'u bu degiskeni bilmez; bu yuzden yalnizca yoklama icin verilir.
pub fn data_dir() -> PathBuf {
    if let Some(override_dir) = std::env::var_os("SERENE_DATA_DIR") {
        let dir = PathBuf::from(override_dir);
        if !dir.as_os_str().is_empty() {
            return dir;
        }
    }
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Serene")
}
