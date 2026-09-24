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

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Firefox'un istedigi host adi; eklentide `runtime.connectNative` ile ayni olmali.
pub const HOST_NAME: &str = "com.serene.nmh";

/// Eklentinin kalici kimligi. Native messaging yalnizca bu kimlige izin verir,
/// bu yuzden eklentinin `browser_specific_settings.gecko.id` alaniyla ayni olmali.
pub const EXTENSION_ID: &str = "serene@izzet.local";

pub const NMH_EXE: &str = "serene-nmh.exe";

const REG_PATH: &str = r"Software\Mozilla\NativeMessagingHosts\com.serene.nmh";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct HostManifest {
    pub name: String,
    pub description: String,
    pub path: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub allowed_extensions: Vec<String>,
}

pub fn data_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Serene")
}

pub fn nmh_dir() -> PathBuf {
    data_dir().join("nmh")
}

pub fn manifest_path() -> PathBuf {
    nmh_dir().join(format!("{HOST_NAME}.json"))
}

pub fn log_path() -> PathBuf {
    nmh_dir().join("register.log")
}

/// Calisan ikilinin yanindaki `serene-nmh.exe` yolunu bulur.
pub fn nmh_exe_path() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| format!("Ikili yolu okunamadi: {e}"))?;
    let dir = exe
        .parent()
        .ok_or_else(|| "Ikili klasoru bulunamadi".to_string())?;
    Ok(dir.join(NMH_EXE))
}

fn write_log(message: &str) {
    let dir = nmh_dir();
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let line = format!("[{stamp}] {message}\n");
    use std::io::Write;
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path())
    {
        let _ = file.write_all(line.as_bytes());
    }
}

fn build_manifest(exe: &Path) -> HostManifest {
    HostManifest {
        name: HOST_NAME.to_string(),
        description: "Serene indirme yoneticisi koprusu".to_string(),
        path: exe.to_string_lossy().to_string(),
        kind: "stdio".to_string(),
        allowed_extensions: vec![EXTENSION_ID.to_string()],
    }
}

/// Manifesti yazar ve kayit defteri anahtarini kurar. Zaten ayni yoldaysa
/// kayit defterine dokunmaz.
pub fn register() -> Result<PathBuf, String> {
    let exe = nmh_exe_path()?;
    if !exe.exists() {
        let message = format!("{} bulunamadi: {}", NMH_EXE, exe.display());
        write_log(&format!("HATA: {message}"));
        return Err(message);
    }

    let manifest = build_manifest(&exe);
    let path = manifest_path();

    std::fs::create_dir_all(nmh_dir()).map_err(|e| format!("Klasor olusturulamadi: {e}"))?;
    let json = serde_json::to_string_pretty(&manifest)
        .map_err(|e| format!("Manifest olusturulamadi: {e}"))?;
    std::fs::write(&path, json).map_err(|e| format!("Manifest yazilamadi: {e}"))?;

    let value = path.to_string_lossy().to_string();
    if read_registry_value().as_deref() == Some(value.as_str()) {
        write_log(&format!("Kayit zaten guncel: {value}"));
        return Ok(path);
    }

    write_registry_value(&value)?;

    // Yazilan degeri geri oku: yetki veya WOW64 yonlendirmesi gibi
    // durumlarda kayit sessizce basarisiz olabilir.
    if !is_registered() {
        let message = "Kayit defteri yazildi ama dogrulanamadi".to_string();
        write_log(&format!("HATA: {message}"));
        return Err(message);
    }

    write_log(&format!("Kayit yapildi: {value}"));
    Ok(path)
}

pub fn unregister() -> Result<(), String> {
    use winreg::enums::HKEY_CURRENT_USER;
    use winreg::RegKey;

    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    match hkcu.delete_subkey_all(REG_PATH) {
        Ok(()) => {
            write_log("Kayit silindi");
            let _ = std::fs::remove_file(manifest_path());
            Ok(())
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            write_log("Kayit zaten yok");
            Ok(())
        }
        Err(err) => {
            let message = format!("Kayit silinemedi: {err}");
            write_log(&format!("HATA: {message}"));
            Err(message)
        }
    }
}

pub fn read_registry_value() -> Option<String> {
    use winreg::enums::{HKEY_CURRENT_USER, KEY_READ};
    use winreg::RegKey;

    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let key = hkcu.open_subkey_with_flags(REG_PATH, KEY_READ).ok()?;
    key.get_value::<String, _>("").ok()
}

fn write_registry_value(value: &str) -> Result<(), String> {
    use winreg::enums::{HKEY_CURRENT_USER, KEY_WRITE};
    use winreg::RegKey;

    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let (key, _) = hkcu
        .create_subkey(REG_PATH)
        .map_err(|e| format!("Kayit anahtari olusturulamadi: {e}"))?;
    key.set_value("", &value.to_string())
        .map_err(|e| format!("Kayit degeri yazilamadi: {e}"))?;
    let _ = KEY_WRITE;
    Ok(())
}

/// Kayit defterindeki yol ile diskteki manifest ayni mi?
pub fn is_registered() -> bool {
    let Some(value) = read_registry_value() else {
        return false;
    };
    let path = PathBuf::from(&value);
    path.exists()
}
