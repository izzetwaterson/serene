//! Arayuzden gelen cagrilarin motora yonlendigi yer.
//!
//! Tauri kabugundaki `commands.rs` ile birebir ayni isi yapar; tek fark
//! buradaki cagrilarin `serene_core` tipleri yerine kendi DTO'larimizi
//! donmesidir. Hicbir indirme mantigi burada degildir.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serene_core::engine;
use serene_core::enqueue::{self, EnqueueOptions};
use serene_core::manager::DownloadManager;
use serene_core::models::{DownloadKind, DownloadMeta, Settings};
use serene_core::platform;
use serene_core::runtime;

use crate::api::dto::{AppConfig, Capture, DiskSpace, LinkStatus, MediaKind, Task};
use crate::state;

/// Ag isi gorevleri motorun kendi havuzunda surulur: FRB'nin bekletici havuzu
/// bir tokio calisma zamani degildir ve reqwest oradan yonetilemez.
async fn in_engine<T: Send + 'static>(
    future: impl std::future::Future<Output = T> + Send + 'static,
) -> Result<T, String> {
    runtime::spawn(future).await.map_err(|err| err.to_string())
}

fn manager() -> Result<Arc<DownloadManager>, String> {
    state::core().map(|core| Arc::clone(&core.manager))
}

fn task_path(id: &str) -> Result<PathBuf, String> {
    let entry = manager()?.find(id).ok_or("Gorev bulunamadi")?;
    let meta = entry.meta.lock().unwrap();
    Ok(PathBuf::from(&meta.dest))
}

fn options(
    dest_dir: Option<String>,
    referer: Option<String>,
    cookie: Option<String>,
    user_agent: Option<String>,
    kind: Option<MediaKind>,
    source: Option<String>,
) -> EnqueueOptions {
    EnqueueOptions {
        dest_dir,
        referer,
        cookie,
        user_agent,
        kind: kind.map(DownloadKind::from).unwrap_or_default(),
        source,
        hold: false,
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn list_tasks() -> Vec<Task> {
    manager()
        .map(|manager| manager.snapshot().into_iter().map(Task::from).collect())
        .unwrap_or_default()
}

#[flutter_rust_bridge::frb(sync)]
pub fn list_captures() -> Vec<Capture> {
    manager()
        .map(|manager| manager.captures().into_iter().map(Capture::from).collect())
        .unwrap_or_default()
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_settings() -> AppConfig {
    manager()
        .map(|manager| manager.settings().into())
        .unwrap_or_else(|_| Settings::default().into())
}

/// Kopru kuruluncaya kadar sifir doner: arayuz gostergesi "bagli degil" cizilir.
#[flutter_rust_bridge::frb(sync)]
pub fn bridge_status() -> LinkStatus {
    state::core()
        .map(|core| core.bridge.status().into())
        .unwrap_or_default()
}

#[allow(clippy::too_many_arguments)]
pub async fn add_download(
    url: String,
    dest_dir: Option<String>,
    referer: Option<String>,
    cookie: Option<String>,
    user_agent: Option<String>,
    kind: Option<MediaKind>,
    source: Option<String>,
) -> Result<Task, String> {
    let manager = manager()?;
    let opts = options(dest_dir, referer, cookie, user_agent, kind, source);
    // Motorun havuzuna tasinan gelecek yalnizca kendine ait degerleri tasir.
    let meta = in_engine(async move { enqueue::enqueue_download(&manager, &url, opts).await })
        .await??;
    Ok(meta.into())
}

/// Yakalanan medyayi indirmeye cevirir; tur kayittan gelir.
pub async fn download_capture(id: String, dest_dir: Option<String>) -> Result<Task, String> {
    let manager = manager()?;
    let item = manager.capture(&id).ok_or("Yakalama bulunamadi")?;
    let kind = Some(item.kind.into());
    let url = item.url;
    let meta = in_engine(async move {
        let opts = options(dest_dir, None, None, None, kind, Some("capture".into()));
        enqueue::enqueue_download(&manager, &url, opts).await
    })
    .await??;
    Ok(meta.into())
}

pub async fn pause_download(id: String) -> Result<(), String> {
    manager()?.pause(&id)
}

pub async fn resume_download(id: String) -> Result<(), String> {
    manager()?.resume(&id)
}

pub async fn retry_download(id: String) -> Result<(), String> {
    manager()?.retry(&id)
}

pub async fn remove_download(id: String, delete_file: bool) -> Result<(), String> {
    manager()?.remove(&id, delete_file)
}

/// Onay bekleyen ya da duraklatilmis gorevin kayit yerini ve adini degistirir.
pub async fn set_task_dest(
    id: String,
    dest_dir: String,
    filename: String,
) -> Result<Task, String> {
    let dir = dest_dir.trim();
    if dir.is_empty() {
        return Err("Klasor yolu bos olamaz".into());
    }
    let name = engine::sanitize_filename(&filename).ok_or("Gecersiz dosya adi")?;
    let meta: DownloadMeta = manager()?.relocate(&id, Path::new(dir), &name)?;
    Ok(meta.into())
}

pub async fn clear_completed() -> Result<i32, String> {
    Ok(manager()?.clear_completed() as i32)
}

pub async fn dismiss_capture(id: String) -> Result<(), String> {
    manager()?.dismiss_capture(&id)
}

pub async fn clear_captures() -> Result<i32, String> {
    Ok(manager()?.clear_captures() as i32)
}

pub async fn update_settings(settings: AppConfig) -> Result<AppConfig, String> {
    let manager = manager()?;
    let mut next: Settings = settings.into();
    next.max_concurrent = next.max_concurrent.clamp(1, 16);
    next.connections = next.connections.clamp(1, 16);
    if next.download_dir.trim().is_empty() {
        next.download_dir = serene_core::models::default_download_dir();
    }
    std::fs::create_dir_all(&next.download_dir).map_err(|e| format!("Klasor olusturulamadi: {e}"))?;
    manager.update_settings(next.clone());
    manager.emit_full();
    Ok(next.into())
}

pub async fn get_disk_usage() -> Result<DiskSpace, String> {
    let dir = manager()?.settings().download_dir;
    Ok(platform::disk_usage(&dir)?.into())
}

pub async fn open_task_file(id: String) -> Result<(), String> {
    platform::open_path(&task_path(&id)?)
}

pub async fn reveal_task_file(id: String) -> Result<(), String> {
    platform::reveal_path(&task_path(&id)?)
}
