//! Firefox native messaging host kaydi.
//!
//! Bu kutuphane bilerek Tauri'ye ve indirme motoruna bagimli degil: hem
//! `serene.exe` hem de kucuk `serene-nmh.exe` ikilisi ayni kaydi paylasir.
//! `serene-nmh.exe` motoru linklemedigi icin ~1 MB kalir ve hizli acilir.
//!
//! Kayit iki parcalidir:
//!   1. `%APPDATA%\Serene\nmh\com.serene.nmh.json` — host manifesti
//!   2. `HKCU\Software\Mozilla\NativeMessagingHosts\com.serene.nmh` — Firefox'un
//!      manifesti bulmak icin okudugu kayit defteri anahtari
//!
//! # Test edilebilirlik
//!
//! Karar mantigi ile yan etkiler ayridir:
//!   * yol kurma `*_in(taban)` yardimcilarina, hepsi saf,
//!   * `register`/`unregister` birer adim listesi yerine `RegisterStep` /
//!     `UnregisterStep` dondurur: adim, gunluk satiri ve hata mesaji saf
//!     fonksiyonlardan gelir,
//!   * manifest yazimi `write_manifest_to(klasor, ikili)` ile ayridir; hedef
//!     klasor parametresidir.
//!
//! Boylece `tests/` altindaki testler kayit defterine ya da
//! `%APPDATA%\Serene`'ye hic dokunmadan her karari dogrulayabilir.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Firefox'un istedigi host adi; eklentide `runtime.connectNative` ile ayni olmali.
pub const HOST_NAME: &str = "com.serene.nmh";

/// Eklentinin kalici kimligi. Native messaging yalnizca bu kimlige izin verir,
/// bu yuzden eklentinin `browser_specific_settings.gecko.id` alaniyla ayni olmali.
pub const EXTENSION_ID: &str = "serene@izzet.local";

pub const NMH_EXE: &str = "serene-nmh.exe";

/// Kullanici anahtari (`HKEY_CURRENT_USER`) altindaki kayit. Anahtarin *varsayilan*
/// degeri manifest dosyasinin mutlak yoludur; deger adi bos birakildigi icin
/// `get_value::<String, _>("")` ile okunur.
///
/// SOZLESME: `scripts/check_nmh.mjs` ve NSIS kurulum paketi ayni yolu yazar.
pub const REG_PATH: &str = r"Software\Mozilla\NativeMessagingHosts\com.serene.nmh";

/// Alt klasor ve dosya adlari. Konum degistirilirse hem manifest hem guncelleme
/// gunlugu birlikte tasinir; ayri ayri sabit tutulmaz.
const DATA_DIR_NAME: &str = "Serene";
const NMH_SUBDIR: &str = "nmh";
const LOG_FILE: &str = "register.log";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct HostManifest {
    pub name: String,
    pub description: String,
    pub path: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub allowed_extensions: Vec<String>,
}

/* ---------- yol kurma (saf) ---------- */

/// Verilen kok altindaki veri klasoru.
pub fn data_dir_in(base: &Path) -> PathBuf {
    base.join(DATA_DIR_NAME)
}

/// Verilen veri klasoru altindaki `nmh` klasoru.
pub fn nmh_dir_in(data: &Path) -> PathBuf {
    data.join(NMH_SUBDIR)
}

/// Verilen kok altindaki host manifestinin tam yolu.
pub fn manifest_path_in(base: &Path) -> PathBuf {
    nmh_dir_in(&data_dir_in(base)).join(format!("{HOST_NAME}.json"))
}

/// Verilen kok altindaki kayit gunlugu.
pub fn log_path_in(base: &Path) -> PathBuf {
    nmh_dir_in(&data_dir_in(base)).join(LOG_FILE)
}

pub fn data_dir() -> PathBuf {
    // Cekirdek (`store::data_dir`) `SERENE_DATA_DIR` verilmisse onu kullanir;
    // host ayni kapiyi tutmazsa kopru dosyasi iki ayri yerde aranir ve izole
    // kosumlar sessizce baglanamaz.
    if let Some(dir) = std::env::var_os("SERENE_DATA_DIR") {
        return PathBuf::from(dir);
    }
    data_dir_in(&config_base())
}

pub fn nmh_dir() -> PathBuf {
    nmh_dir_in(&data_dir())
}

pub fn manifest_path() -> PathBuf {
    manifest_path_in(&config_base())
}

pub fn log_path() -> PathBuf {
    log_path_in(&config_base())
}

/// `dirs` bazi ortamlarda `None` doner; o durumda goreli koke dusulur.
fn config_base() -> PathBuf {
    dirs::config_dir().unwrap_or_else(|| PathBuf::from("."))
}

/// Ikili yolunden `serene-nmh.exe` yolunu cikarir. Calisan surece bagli
/// olmayan tek yer burasi: `nmh_exe_path` yalnizca `current_exe` ile bunu
/// cagirir, boylece hata durumu da testlenebilir.
pub fn nmh_exe_from(exe: &Path) -> Result<PathBuf, String> {
    let dir = exe
        .parent()
        .ok_or_else(|| "Ikili klasoru bulunamadi".to_string())?;
    Ok(dir.join(NMH_EXE))
}

/// Calisan ikilinin yanindaki `serene-nmh.exe` yolunu bulur.
pub fn nmh_exe_path() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| format!("Ikili yolu okunamadi: {e}"))?;
    nmh_exe_from(&exe)
}

/// Firefox'un kayit defterinden okudugu komut: manifest dosyasinin yolu.
/// Bosluk iceren yollarda tirnak gerekmez - deger dogrudan dosya yoludur.
pub fn registry_value(manifest_path: &Path) -> String {
    manifest_path.to_string_lossy().to_string()
}

/* ---------- gunluk (saf bicim + dosya) ---------- */

/// Gunluk satiri: `[unix_saniye] mesaj`. Damgasi ayri verildigi icin
/// satirin bicimi testte belirlenebilir.
pub fn log_line(stamp: u64, message: &str) -> String {
    format!("[{stamp}] {message}\n")
}

fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn write_log(message: &str) {
    let dir = nmh_dir();
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let line = log_line(unix_now(), message);
    use std::io::Write;
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path())
    {
        let _ = file.write_all(line.as_bytes());
    }
}

/* ---------- kayit adimlari (saf karar) ---------- */

/// `register` bir adimda ne yapacagini bildirir. Yurutme sirasi `register`
/// icinde birebir korunur; buradaki turler yalnizca "hangi karar" sorusunu
/// yanitlar, yan etkileri yapmazlar.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RegisterStep {
    /// Ikili diskte yok: hicbir sey yazilmaz, hata doner.
    MissingExecutable(PathBuf),
    /// Manifest yazildi ve kayit defteri zaten ayni yoli gostermiyor.
    NeedsRegistryWrite(String),
    /// Kayit defterindeki deger zaten ayni: kayit defterine dokunulmaz.
    AlreadyCurrent(String),
    /// Deger yazildi ama geri okunamadi (yetki ya da WOW64 yonlendirmesi).
    NotVerified(String),
    /// Kayit yazildi ve dogrulandi.
    Registered(String),
}

impl RegisterStep {
    /// Gunluke yazilacak satiri; yazilmayan adimlar `None` doner.
    pub fn log(&self) -> Option<String> {
        match self {
            Self::MissingExecutable(exe) => Some(format!(
                "HATA: {} bulunamadi: {}",
                NMH_EXE,
                exe.display()
            )),
            Self::NeedsRegistryWrite(_) => None,
            Self::AlreadyCurrent(value) => Some(format!("Kayit zaten guncel: {value}")),
            Self::NotVerified(_) => Some("HATA: Kayit defteri yazildi ama dogrulanamadi".into()),
            Self::Registered(value) => Some(format!("Kayit yapildi: {value}")),
        }
    }

    /// Kullaniciya dondurulecek hata; basarili adimlarda `None`.
    pub fn error(&self) -> Option<String> {
        match self {
            Self::MissingExecutable(exe) => Some(format!("{} bulunamadi: {}", NMH_EXE, exe.display())),
            Self::NeedsRegistryWrite(_) | Self::AlreadyCurrent(_) | Self::Registered(_) => None,
            Self::NotVerified(_) => Some("Kayit defteri yazildi ama dogrulanamadi".into()),
        }
    }
}

/// Manifest yazildi; kayit defterinde okunan deger ayni mi?
/// Ayniysa yazma yoktur: kayit defterine gereksiz dokunmamak `register`in
/// "zaten guncel" cikisidir.
pub fn registry_step(value: &str, current: Option<&str>) -> RegisterStep {
    if current == Some(value) {
        RegisterStep::AlreadyCurrent(value.to_string())
    } else {
        RegisterStep::NeedsRegistryWrite(value.to_string())
    }
}

/// Deger yazildi; geri okuma dogrulandi mi? Dogrulanmadiysa sessizce basarili
/// donmek, Firefox'un hicbir sey bulamadigi bir kayit birakir.
pub fn verification_step(value: &str, verified: bool) -> RegisterStep {
    if verified {
        RegisterStep::Registered(value.to_string())
    } else {
        RegisterStep::NotVerified(value.to_string())
    }
}

/// `unregister` bir adimda ne yapacagini bildirir. `AlreadyAbsent` hata
/// degildir: istenen durum zaten saglanmistir (kullanicinin kaydi elle silmis
/// olmasi normaldir).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UnregisterStep {
    /// Anahtar silindi; manifest dosyasi da silinir.
    Removed,
    /// Anahtar zaten yok; hata degil, manifest oldugu gibi birakilir.
    AlreadyAbsent,
    /// Baska bir hata: mesaj doner, manifest silinmez.
    Failed(String),
}

impl UnregisterStep {
    /// Silme hatasini adima cevirir.
    pub fn from_error(err: &std::io::Error) -> Self {
        if err.kind() == std::io::ErrorKind::NotFound {
            Self::AlreadyAbsent
        } else {
            Self::Failed(format!("Kayit silinemedi: {err}"))
        }
    }

    /// Gunluke yazilacak satiri; hicbir yerde yazilmaz.
    pub fn log(&self) -> Option<&'static str> {
        match self {
            Self::Removed => Some("Kayit silindi"),
            Self::AlreadyAbsent => Some("Kayit zaten yok"),
            Self::Failed(_) => None,
        }
    }

    /// Kullaniciya dondurulecek hata.
    pub fn error(&self) -> Option<String> {
        match self {
            Self::Failed(message) => Some(message.clone()),
            Self::Removed | Self::AlreadyAbsent => None,
        }
    }

    /// Manifest dosyasi bu adimdan sonra silinmeli mi?
    pub fn removes_manifest(&self) -> bool {
        matches!(self, Self::Removed)
    }
}

/* ---------- manifest ---------- */

pub fn build_manifest(exe: &Path) -> HostManifest {
    HostManifest {
        name: HOST_NAME.to_string(),
        description: "Serene indirme yoneticisi koprusu".to_string(),
        path: exe.to_string_lossy().to_string(),
        kind: "stdio".to_string(),
        allowed_extensions: vec![EXTENSION_ID.to_string()],
    }
}

/// Manifestin diske yazilacak hali. Firefox'un okudugu JSON tam olarak budur.
pub fn manifest_json(manifest: &HostManifest) -> Result<String, String> {
    serde_json::to_string_pretty(manifest).map_err(|e| format!("Manifest olusturulamadi: {e}"))
}

/// Manifesti verilen klasore yazar ve dosyanin yolunu dondurur.
///
/// Klasor ve dosya sistemi disinda tek yan etki yoktur; kayit defteri buraya
/// girmez. `register` bunu `nmh_dir()` ile cagirir, testler gecici klasorle.
pub fn write_manifest_to(dir: &Path, exe: &Path) -> Result<PathBuf, String> {
    let manifest = build_manifest(exe);
    let path = dir.join(format!("{HOST_NAME}.json"));

    std::fs::create_dir_all(dir).map_err(|e| format!("Klasor olusturulamadi: {e}"))?;
    let json = manifest_json(&manifest)?;
    std::fs::write(&path, json).map_err(|e| format!("Manifest yazilamadi: {e}"))?;
    Ok(path)
}

/* ---------- yan etkiler ---------- */

/// Manifesti yazar ve kayit defteri anahtarini kurar. Zaten ayni yoldaysa
/// kayit defterine dokunmaz.
pub fn register() -> Result<PathBuf, String> {
    let exe = nmh_exe_path()?;
    if !exe.exists() {
        let step = RegisterStep::MissingExecutable(exe);
        if let Some(line) = step.log() {
            write_log(&line);
        }
        // Ikili yok her zaman hatadir: `log` ile ayni sart.
        return Err(step.error().expect("eksik ikili hata dondurur"));
    }

    let path = write_manifest_to(&nmh_dir(), &exe)?;
    let value = registry_value(&path);

    let step = registry_step(&value, read_registry_value().as_deref());
    if let Some(line) = step.log() {
        write_log(&line);
    }
    if let Some(message) = step.error() {
        return Err(message);
    }
    if matches!(step, RegisterStep::AlreadyCurrent(_)) {
        return Ok(path);
    }

    write_registry_value(&value)?;

    // Yazilan degeri geri oku: yetki veya WOW64 yonlendirmesi gibi
    // durumlarda kayit sessizce basarisiz olabilir.
    let step = verification_step(&value, is_registered());
    if let Some(line) = step.log() {
        write_log(&line);
    }
    match step.error() {
        Some(message) => Err(message),
        None => Ok(path),
    }
}

pub fn unregister() -> Result<(), String> {
    let step = match delete_registry_key() {
        Ok(()) => UnregisterStep::Removed,
        Err(err) => UnregisterStep::from_error(&err),
    };

    if let Some(line) = step.log() {
        write_log(line);
    }
    // Hata adiminin `log()`u `None`: `HATA:` oneki `unregister` kendisi ekler.
    if let Some(message) = step.error() {
        write_log(&format!("HATA: {message}"));
        return Err(message);
    }
    if step.removes_manifest() {
        let _ = std::fs::remove_file(manifest_path());
    }
    Ok(())
}

/// Kayit defterindeki deger, manifest olarak kullanilabilir mi? Anahtar ya da
/// deger yoksa `false`; deger okunabilir ama dosya yoksa da `false` (Firefox
/// manifesti acamaz).
pub fn registration_is_usable(value: Option<&str>) -> bool {
    value.is_some_and(|value| Path::new(value).exists())
}

pub fn read_registry_value() -> Option<String> {
    use winreg::enums::{HKEY_CURRENT_USER, KEY_READ};
    use winreg::RegKey;

    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let key = hkcu.open_subkey_with_flags(REG_PATH, KEY_READ).ok()?;
    key.get_value::<String, _>("").ok()
}

fn delete_registry_key() -> std::io::Result<()> {
    use winreg::enums::HKEY_CURRENT_USER;
    use winreg::RegKey;

    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    hkcu.delete_subkey_all(REG_PATH)
}

fn write_registry_value(value: &str) -> Result<(), String> {
    use winreg::enums::HKEY_CURRENT_USER;
    use winreg::RegKey;

    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let (key, _) = hkcu
        .create_subkey(REG_PATH)
        .map_err(|e| format!("Kayit anahtari olusturulamadi: {e}"))?;
    key.set_value("", &value.to_string())
        .map_err(|e| format!("Kayit degeri yazilamadi: {e}"))
}

/// Kayit defterindeki yol ile diskteki manifest ayni mi?
pub fn is_registered() -> bool {
    registration_is_usable(read_registry_value().as_deref())
}
