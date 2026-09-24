//! Indirme gostermek: arayuzun ve yerel koprunun paylastigi tek yol.
//!
//! Buraya kadarki katman "gorevi kurar"; kabuk (Tauri/Flutter) yalnizca
//! kendi komut/FFI kabisini saglar.

use std::path::PathBuf;
use std::sync::Arc;

use uuid::Uuid;

use crate::category;
use crate::engine;
use crate::manager::DownloadManager;
use crate::models::{now_secs, Category, DownloadKind, DownloadMeta, Settings, Status};

/// Girdiyi gecerli bir http(s) URL'sine cevirir.
/// Sema yazilmamissa https varsayilir; torrent baglantilari acikca reddedilir.
pub fn normalize_url(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("Baglanti bos olamaz".into());
    }
    if trimmed.to_ascii_lowercase().starts_with("magnet:") {
        return Err("Miknatis/torrent baglantilari bu surumde desteklenmiyor".into());
    }

    let candidate = if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        trimmed.to_string()
    } else if trimmed.contains("://") {
        return Err("Yalnizca http ve https baglantilari destekleniyor".into());
    } else {
        format!("https://{trimmed}")
    };

    let parsed = reqwest::Url::parse(&candidate).map_err(|_| "Gecersiz baglanti".to_string())?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err("Yalnizca http ve https baglantilari destekleniyor".into());
    }
    if parsed.host_str().is_none() {
        return Err("Baglantida sunucu adi yok".into());
    }
    Ok(parsed.to_string())
}

/// Gorev kurulurken tarayicidan gelebilen istege bagli istek ayrintilari.
/// Arayuz yalnizca `dest_dir` gecer; digerleri varsayilan kalir.
#[derive(Clone, Debug, Default)]
pub struct EnqueueOptions {
    pub dest_dir: Option<String>,
    pub referer: Option<String>,
    pub cookie: Option<String>,
    pub user_agent: Option<String>,
    pub kind: DownloadKind,
    pub source: Option<String>,
    /// Gorevi olustur ama baslatma; arayuz onay penceresini gosterir.
    pub hold: bool,
}

/// Tarayicidan devralinan indirme, kullanici bilgi penceresinde karar verene
/// kadar bekletilir. Medya yakalamalari (panelden secilir) ve elle girilen
/// adresler beklemez.
pub fn should_hold(source: Option<&str>, settings: &Settings) -> bool {
    settings.confirm_browser_download && matches!(source, Some("download") | Some("menu"))
}

pub async fn enqueue_download(
    manager: &Arc<DownloadManager>,
    url: &str,
    opts: EnqueueOptions,
) -> Result<DownloadMeta, String> {
    let EnqueueOptions {
        dest_dir,
        referer,
        cookie,
        user_agent,
        kind,
        source,
        hold,
    } = opts;
    let normalized = normalize_url(url)?;

    let settings = manager.settings();
    let dir = dest_dir
        .filter(|d| !d.trim().is_empty())
        .unwrap_or_else(|| settings.download_dir.clone());
    let dir_path = PathBuf::from(&dir);
    std::fs::create_dir_all(&dir_path).map_err(|e| format!("Klasor olusturulamadi: {e}"))?;

    let client = manager.client();
    let id = Uuid::new_v4().to_string();
    let temp_dir = dir_path.join(".serene").join(&id);

    // Basliklar meta ile tasindigi ve probe da onlari kullandigi icin meta
    // once kurulur; boyut / ad / kategori alanlari probe sonucuyla dolar.
    let mut meta = DownloadMeta {
        id,
        url: normalized,
        filename: String::new(),
        dest: String::new(),
        temp_dir: temp_dir.to_string_lossy().to_string(),
        total: 0,
        downloaded: 0,
        speed: 0.0,
        status: Status::Queued,
        error: None,
        category: Category::Other,
        resumable: false,
        segments: Vec::new(),
        created_at: now_secs(),
        finished_at: None,
        etag: None,
        referer,
        cookie,
        user_agent,
        kind,
        source,
        pending: false,
    };

    let probe = engine::probe(&client, &meta.url, &meta)
        .await
        .map_err(|e| format!("{e:#}"))?;

    let filename = probe
        .filename
        .clone()
        .or_else(|| engine::filename_from_url(&probe.final_url))
        .or_else(|| engine::filename_from_url(&meta.url))
        .unwrap_or_else(|| "indirme".to_string());

    let dest = engine::unique_dest(&dir_path, &filename);
    meta.filename = dest
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("indirme")
        .to_string();
    meta.category = category::classify(&meta.filename);
    meta.dest = dest.to_string_lossy().to_string();
    meta.resumable = probe.resumable;
    meta.segments = if probe.resumable {
        engine::plan_segments(probe.total, settings.connections)
    } else {
        engine::plan_segments(0, 1)
    };
    meta.total = probe.total;
    meta.etag = probe.etag;

    // Bekletilen gorev duraklatilmis dogar: kuyruk yalnizca `Queued` isleri
    // baslattigi icin kendiliginden calismaz.
    if hold {
        meta.status = Status::Paused;
        meta.pending = true;
    }

    manager.insert(meta.clone());
    manager.emit_full();
    manager.persist_now();

    if hold {
        manager.emit_handoff(&meta);
    } else {
        manager.pump();
    }
    Ok(meta)
}
