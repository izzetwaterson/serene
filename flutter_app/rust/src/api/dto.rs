//! Dart'a tasinan veri tipleri.
//!
//! Cekirdegin kendi yapisal dogrudan kullanilmiyor: FRB, baska bir kutphanede
//! tanimli tipler icin donusum kodu uretemiyor (yetim kurali). Ayrica cekirdek
//! `u64` kullaniyor; FRB onu Dart tarafinda `BigInt`'e karsilik getiriyor, o
//! yuzden arayuzde hesap yapilabilir kilsin diye bayt alanlari `i64`'e iniyor.

use serene_core::bridge::BridgeStatus;
use serene_core::manager::ProgressTick;
use serene_core::models::{CaptureItem, Category, DownloadKind, DownloadMeta, DiskUsage, SegmentInfo, Settings, Status};

/// Boyutu bilinmeyen parcalar `u64::MAX` ile isaretlenir; Dart'ta buyuk ama
/// pozitif bir sayi, bos gorunmesindendir iyidir.
fn fit(value: u64) -> i64 {
    value.min(i64::MAX as u64) as i64
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaskStatus {
    Queued,
    Downloading,
    Paused,
    Completed,
    Failed,
}

impl From<Status> for TaskStatus {
    fn from(value: Status) -> Self {
        match value {
            Status::Queued => Self::Queued,
            Status::Downloading => Self::Downloading,
            Status::Paused => Self::Paused,
            Status::Completed => Self::Completed,
            Status::Failed => Self::Failed,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileCategory {
    Video,
    Audio,
    Image,
    Document,
    Software,
    Archive,
    Other,
}

impl From<Category> for FileCategory {
    fn from(value: Category) -> Self {
        match value {
            Category::Video => Self::Video,
            Category::Audio => Self::Audio,
            Category::Image => Self::Image,
            Category::Document => Self::Document,
            Category::Software => Self::Software,
            Category::Archive => Self::Archive,
            Category::Other => Self::Other,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum MediaKind {
    #[default]
    File,
    Hls,
    Dash,
}

impl From<DownloadKind> for MediaKind {
    fn from(value: DownloadKind) -> Self {
        match value {
            DownloadKind::File => Self::File,
            DownloadKind::Hls => Self::Hls,
            DownloadKind::Dash => Self::Dash,
        }
    }
}

impl From<MediaKind> for DownloadKind {
    fn from(value: MediaKind) -> Self {
        match value {
            MediaKind::File => Self::File,
            MediaKind::Hls => Self::Hls,
            MediaKind::Dash => Self::Dash,
        }
    }
}

/// Tek bir baglanti parcasinin arayuze yansiyan hali.
#[derive(Clone, Debug)]
pub struct Segment {
    pub index: i32,
    pub start: i64,
    pub end: i64,
    pub downloaded: i64,
}

impl From<SegmentInfo> for Segment {
    fn from(value: SegmentInfo) -> Self {
        Self {
            index: value.index as i32,
            start: fit(value.start),
            end: fit(value.end),
            downloaded: fit(value.downloaded),
        }
    }
}

#[derive(Clone, Debug)]
pub struct Task {
    pub id: String,
    pub url: String,
    pub filename: String,
    pub dest: String,
    pub temp_dir: String,
    pub total: i64,
    pub downloaded: i64,
    pub speed: f64,
    pub status: TaskStatus,
    pub error: Option<String>,
    pub category: FileCategory,
    pub resumable: bool,
    pub segments: Vec<Segment>,
    pub created_at: i64,
    pub finished_at: Option<i64>,
    pub etag: Option<String>,
    pub referer: Option<String>,
    pub cookie: Option<String>,
    pub user_agent: Option<String>,
    pub kind: MediaKind,
    pub source: Option<String>,
    pub pending: bool,
}

impl From<DownloadMeta> for Task {
    fn from(value: DownloadMeta) -> Self {
        Self {
            id: value.id,
            url: value.url,
            filename: value.filename,
            dest: value.dest,
            temp_dir: value.temp_dir,
            total: fit(value.total),
            downloaded: fit(value.downloaded),
            speed: value.speed,
            status: value.status.into(),
            error: value.error,
            category: value.category.into(),
            resumable: value.resumable,
            segments: value.segments.into_iter().map(Segment::from).collect(),
            created_at: value.created_at,
            finished_at: value.finished_at,
            etag: value.etag,
            referer: value.referer,
            cookie: value.cookie,
            user_agent: value.user_agent,
            kind: value.kind.into(),
            source: value.source,
            pending: value.pending,
        }
    }
}

/// Ticker'in yayinladigi hafif ilerleme paketi.
#[derive(Clone, Debug)]
pub struct Progress {
    pub id: String,
    pub downloaded: i64,
    pub total: i64,
    pub speed: f64,
}

impl From<ProgressTick> for Progress {
    fn from(value: ProgressTick) -> Self {
        Self {
            id: value.id,
            downloaded: fit(value.downloaded),
            total: fit(value.total),
            speed: value.speed,
        }
    }
}

/// Tarayicidan yakalanan medya kaydi.
#[derive(Clone, Debug)]
pub struct Capture {
    pub id: String,
    pub url: String,
    pub filename: String,
    pub size: i64,
    pub content_type: String,
    pub kind: MediaKind,
    pub site: String,
    pub created_at: i64,
}

impl From<CaptureItem> for Capture {
    fn from(value: CaptureItem) -> Self {
        Self {
            id: value.id,
            url: value.url,
            filename: value.filename,
            size: fit(value.size),
            content_type: value.content_type,
            kind: value.kind.into(),
            site: value.site,
            created_at: value.created_at,
        }
    }
}

#[derive(Clone, Debug)]
pub struct AppConfig {
    pub download_dir: String,
    pub max_concurrent: i32,
    pub connections: i32,
    pub watch_clipboard: bool,
    pub close_to_tray: bool,
    pub confirm_browser_download: bool,
}

impl From<Settings> for AppConfig {
    fn from(value: Settings) -> Self {
        Self {
            download_dir: value.download_dir,
            max_concurrent: value.max_concurrent as i32,
            connections: value.connections as i32,
            watch_clipboard: value.watch_clipboard,
            close_to_tray: value.close_to_tray,
            confirm_browser_download: value.confirm_browser_download,
        }
    }
}

impl From<AppConfig> for Settings {
    fn from(value: AppConfig) -> Self {
        Self {
            download_dir: value.download_dir,
            max_concurrent: value.max_concurrent.max(1) as usize,
            connections: value.connections.max(1) as usize,
            watch_clipboard: value.watch_clipboard,
            close_to_tray: value.close_to_tray,
            confirm_browser_download: value.confirm_browser_download,
        }
    }
}

#[derive(Clone, Debug)]
pub struct DiskSpace {
    pub mount: String,
    pub total: i64,
    pub free: i64,
    pub used: i64,
}

impl From<DiskUsage> for DiskSpace {
    fn from(value: DiskUsage) -> Self {
        Self {
            mount: value.mount,
            total: fit(value.total),
            free: fit(value.free),
            used: fit(value.used),
        }
    }
}

/// Tarayici kopruyunun arayuz gostergesi. Kurulmamis kopru sifirlarla gelir.
#[derive(Clone, Debug, Default)]
pub struct LinkStatus {
    pub port: i32,
    pub version: String,
    pub clients: i32,
}

impl From<BridgeStatus> for LinkStatus {
    fn from(value: BridgeStatus) -> Self {
        Self {
            port: value.port as i32,
            version: value.version,
            clients: value.clients as i32,
        }
    }
}
