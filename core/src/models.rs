use serde::{Deserialize, Serialize};

/// Bir indirme gorevinin yasam dongusu.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Queued,
    Downloading,
    Paused,
    Completed,
    Failed,
}

/// Arayuzdeki "Kategoriler" filtresi icin dosya turu.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Category {
    Video,
    Audio,
    Image,
    Document,
    Software,
    Archive,
    Other,
}

/// Indirme turu. Akis gorevleri (HLS/DASH) sonraki fazlarda ayri yoldan
/// islenir; File varsayilani arayuz ve eski gorevler icin gecerli.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DownloadKind {
    File,
    Hls,
    Dash,
}

impl Default for DownloadKind {
    fn default() -> Self {
        Self::File
    }
}

/// Tek bir baglanti parcasinin araligi ve o ana kadar inen bayt sayisi.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SegmentInfo {
    pub index: u32,
    pub start: u64,
    /// Kapsayici bitis bayti. Boyut bilinmiyorsa `u64::MAX`.
    pub end: u64,
    pub downloaded: u64,
}

/// Arayuze gonderilen tam gorev tanimi.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DownloadMeta {
    pub id: String,
    pub url: String,
    pub filename: String,
    /// Nihai dosya yolu.
    pub dest: String,
    /// Parcalarin yazildigi gecici klasor.
    pub temp_dir: String,
    pub total: u64,
    pub downloaded: u64,
    pub speed: f64,
    pub status: Status,
    pub error: Option<String>,
    pub category: Category,
    pub resumable: bool,
    pub segments: Vec<SegmentInfo>,
    pub created_at: i64,
    pub finished_at: Option<i64>,
    pub etag: Option<String>,
    /// Giris gerektiren / Referer dogrulayan CDN'ler icin tarayicidan gelen
    /// istek basliklari. Hepsi `default`: eski tasks.json yeni alan olmadan
    /// yuklenmeye devam eder.
    #[serde(default)]
    pub referer: Option<String>,
    #[serde(default)]
    pub cookie: Option<String>,
    #[serde(default)]
    pub user_agent: Option<String>,
    #[serde(default)]
    pub kind: DownloadKind,
    /// Gorevi baslatan kaynak (eklenti, pano, arayuz).
    #[serde(default)]
    pub source: Option<String>,
    /// Tarayicidan gelen ve kullanicinin onayini bekleyen gorev. Onaylanana
    /// kadar baslatilmaz; uygulama kapanip acilsa da bu halde kalir.
    #[serde(default)]
    pub pending: bool,
}

/// Tarayici eklentisinin yakaladigi medya adayi. `tasks.json`'a degil
/// `captures.json`'a yazilir; ayni bicim hem eklentiye hem arayuze doner.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureItem {
    pub id: String,
    pub url: String,
    /// Bilinmiyorsa bos.
    pub filename: String,
    /// Bilinmiyorsa 0.
    pub size: u64,
    pub content_type: String,
    pub kind: DownloadKind,
    /// Yakalandigi sayfanin alan adi; bilinmiyorsa bos.
    pub site: String,
    pub created_at: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub download_dir: String,
    pub max_concurrent: usize,
    pub connections: usize,
    pub watch_clipboard: bool,
    /// X dugmesi uygulamayi kapatmak yerine pencereyi tepsiye gizler.
    pub close_to_tray: bool,
    /// Tarayicidan devralinan indirmeler baslamadan once bilgi penceresi cikar.
    pub confirm_browser_download: bool,
    /// Arayuz temasi: `system`, `light` ya da `dark`.
    pub theme: String,
    /// Arayuz dili: `tr` ya da `en`.
    pub language: String,
    /// Windows acilisinda uygulamayi baslatir.
    ///
    /// Gercek tutulmasi `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
    /// anahtarinda `Serene` degeridir; kurulum paketi de ayni anahtari yazar.
    /// Kullanici bu isi Ayarlar'dan ya da kurulumdan yapabilir.
    pub autostart: bool,
    /// Tarayici eklentisi tanitimi gosterildi; ilk acilis penceresi bir daha
    /// kendiliginden acilmaz. Ayarlar panelinde gorunmez, yalnizca bu kapiyi
    /// tutar; "Tarayici yok" rozeti istendiginde yine acar.
    pub extension_offer_done: bool,
}

/// Tema degerini taninan kumesine indirger. Ayar dosyasi elle duzenlenebilir
/// ve eski surumler alani hic yazmaz; ikisi de varsayilana duser.
///
/// Varsayilan `light`: uygulama acildigi anda karanlik pencere kullaniciyi
/// yamirtir, aydinlik her zaman guvenli bir baslangictir.
pub fn normalize_theme(value: &str) -> String {
    match value.trim().to_ascii_lowercase().as_str() {
        "dark" => "dark".to_string(),
        "system" => "system".to_string(),
        _ => "light".to_string(),
    }
}

/// Dil degerini taninan kumesine indirger. Tema ile ayni sekilde eski
/// ayar dosyalari alani hic yazmaz; varsayilan Ingilizce kalir.
pub fn normalize_language(value: &str) -> String {
    match value.trim().to_ascii_lowercase().as_str() {
        "tr" => "tr".to_string(),
        _ => "en".to_string(),
    }
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            download_dir: default_download_dir(),
            max_concurrent: 3,
            connections: 8,
            watch_clipboard: true,
            close_to_tray: true,
            confirm_browser_download: true,
            theme: "light".to_string(),
            language: "en".to_string(),
            // Kurulum da varsayilan olarak Run anahtarini yazar; depolanan deger
            // kayit defteriyle ayni kalir ki ayarlardaki anahtar yaniltmasin.
            autostart: true,
            extension_offer_done: false,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiskUsage {
    pub mount: String,
    pub total: u64,
    pub free: u64,
    pub used: u64,
}

pub fn default_download_dir() -> String {
    dirs::download_dir()
        .or_else(dirs::home_dir)
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|| "C:\\Users\\Public\\Downloads".to_string())
}

pub fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
