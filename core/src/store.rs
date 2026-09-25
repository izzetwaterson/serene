use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::models::{CaptureItem, DownloadMeta, Settings, Status};

/// Dosya adini son ek ile uzatir: `tasks.json` -> `tasks.json.bak`.
/// Gecici adlar da ayni yolla uretilir; boylece `tasks.json.tmp` gibi bir
/// gecici dosya gercek durum dosyasiyla (`tasks.json`) karismaz ve cokmeden
/// kalma bir gecici dosya yanlislikla durum sanilmaz.
fn sibling(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|name| name.to_os_string())
        .unwrap_or_default();
    name.push(suffix);
    path.with_file_name(name)
}

/// Tek bir dosyayi gecici adla yazip hedefin uzerine tasir.
///
/// Gecici dosya `sync_all` ile zorlanir: baytlar diskte degilse rename
/// sonrasi dosya "yeni ama bos" gorunur ve bir sonraki acilista okunamaz.
fn write_atomic(path: &Path, payload: &[u8]) -> io::Result<()> {
    let tmp = sibling(path, ".tmp");
    // Onceki cokmeden kalma gecici dosyayi temizle.
    let _ = fs::remove_file(&tmp);
    {
        let mut file = fs::File::create(&tmp)?;
        file.write_all(payload)?;
        file.sync_all()?;
    }
    // Hedefi once silmeye gerek yok: Windows'ta `fs::rename` zaten
    // `MoveFileExW(..., MOVEFILE_REPLACE_EXISTING)` cagrisidir, yani uzerine
    // yazma tek islemde olur. Silmek yalnizca "iki dosya da yok" penceresi
    // acar; cokme orada yakalarsa veri kaybolur.
    fs::rename(&tmp, path)
}

/// Eldeki birincil dosyadan `.bak` yedegi tazeler.
///
/// Bozuk birincili yedege tasimak iki kopyayi da bozuk birakirdi; bu
/// yuzden once JSON olarak okunabilirligi sinanir. Okunmuyorsa eldeki
/// yedek oldugu gibi birakilir - dosya yoksa zaten yedek yoktur.
///
/// Yedek zaten birincilin ayni baytlarini tasiyorsa yazma atlanir: motor
/// durumu saniyede bir kez kaydeder, her kayitta iki ayri `sync_all`
/// yapmaya gerek yoktur.
fn refresh_backup(path: &Path) -> io::Result<()> {
    let Ok(raw) = fs::read(path) else {
        return Ok(());
    };
    if serde_json::from_slice::<serde_json::Value>(&raw).is_err() {
        return Ok(());
    }
    let bak = sibling(path, ".bak");
    if fs::read(&bak).is_ok_and(|current| current == raw) {
        return Ok(());
    }
    write_atomic(&bak, &raw)
}

/// JSON durumunu yedekli olarak diske yazar.
///
/// Sira: (1) eldeki birincil dosya gecerliyse `.bak` yedegi tazelenir,
/// (2) yeni icerik gecici dosyaya yazilir ve `sync_all` ile zorlanir,
/// (3) `rename` ile hedefin uzerine yazilir. Birincil dosya hicbir an
/// silinmez, bu yuzden okuma aninda iki dosyadan biri her zaman vardir.
pub fn write_json<T: serde::Serialize>(path: &Path, value: &T) -> io::Result<()> {
    let payload = serde_json::to_vec_pretty(value)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    refresh_backup(path)?;
    write_atomic(path, &payload)
}

/// Tek bir dosyayi okur; hata halinde nedenini soyler.
///
/// "Dosya yok" ile "dosya bozuk" ayridir: biri ilk kullanim, digeri veri
/// kaybi demektir ve arayuzde farkli mesaj gerektirir.
fn read_one<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T, String> {
    let raw = match fs::read(path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Err("dosya yok".to_string()),
        Err(err) => return Err(format!("okunamadi: {err}")),
    };
    serde_json::from_slice(&raw).map_err(|err| format!("bozuk JSON: {err}"))
}

/// JSON okur. Birincil dosya yoksa ya da bozuksa `.bak` yedegine duser;
/// yedek de kullanilamiyorsa `None` doner ve cagiran varsayilana duser.
///
/// Onemli ayrim burada: "okunamadi" ile "bos" ayni sey degildir. Eski
/// surum `None` deyip `load_*` fonksiyonlari bos liste uretiyordu, bir
/// sonraki `save_*` de o bos listeyi dosyaya yaziyordu; tek bozuk bayt
/// tum indirme gecmisini kalici olarak siliyordu.
pub fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Option<T> {
    match read_one(path) {
        Ok(value) => Some(value),
        Err(primary) => match read_one(&sibling(path, ".bak")) {
            Ok(value) => {
                eprintln!(
                    "[depo] {} okunamadi ({primary}); .bak yedeginden geri yuklendi",
                    path.display()
                );
                Some(value)
            }
            // Ikisi de yoksa ilk kullanim; sessizce varsayilana dusmek dogru.
            Err(_) => None,
        },
    }
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
    if let Err(err) = write_json(path, &tasks) {
        record_persist_error(path, &err);
    }
}

pub fn load_captures(path: &Path) -> Vec<CaptureItem> {
    read_json(path).unwrap_or_default()
}

pub fn save_captures(path: &Path, items: &[CaptureItem]) {
    if let Err(err) = write_json(path, &items) {
        record_persist_error(path, &err);
    }
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
    if let Err(err) = write_json(path, settings) {
        record_persist_error(path, &err);
    }
}

/// Son yazma hatasinin ozeti. `save_*` imzalari geriye donuk uyum icin
/// degistirilemez (cagiran kodlar sonucu kullanmiyor), bu yuzden hata
/// burada biriktirilir.
static PERSIST_ERROR: Mutex<Option<String>> = Mutex::new(None);

/// Kaydedilemeyen veri varsa ozetini doner ve kaydi temizler.
///
/// KAYIT: `manager.rs` bunu `persist_now` / `persist_captures` /
/// `update_settings` sonrasi cagirip arayuzde gorunur bir uyari olarak
/// gostermeli. Kimse okumazsa hata yine de `eprintln!` ile konsola duser;
/// bu kayit yalnizca arayuza kadar tasinabilmesi icin var.
pub fn take_persist_error() -> Option<String> {
    PERSIST_ERROR.lock().ok()?.take()
}

/// Ilk hatayi tutar: sonraki yazmalar ayni disk/izin sebebiyle basarisiz
/// olacaksa tekrar etmeye deger degil.
fn record_persist_error(path: &Path, err: &io::Error) {
    let message = format!("{} yazilamadi: {err}", path.display());
    eprintln!("[depo] {message}");
    if let Ok(mut slot) = PERSIST_ERROR.lock() {
        slot.get_or_insert(message);
    }
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
