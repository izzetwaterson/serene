//! Isletim kabugi: dosya acma/gosterme, disk kullanimi ve otomatik baslatma.
//!
//! Arayuzden bagimsiz olduklari icin motorla birlikte burada yasiyorlar;
//! her kabuk ayni davranisi tekrar yazmak zorunda kalmiyor.

use std::path::Path;
use std::process::Command;

use crate::models::DiskUsage;

pub fn reveal_path(path: &Path) -> Result<(), String> {
    // Explorer `/select,` ifadesini tek arguman olarak bekler; path icinde tirnak
    // kullanmak Command'in kendi kacis mantigiyla cakisir, bu yuzden birakmayiz.
    Command::new("explorer")
        .arg(format!("/select,{}", path.display()))
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("Gezgin acilamadi: {e}"))
}

pub fn open_path(path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Err("Dosya diskte bulunamadi".into());
    }
    Command::new("explorer")
        .arg(path.as_os_str())
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("Dosya acilamadi: {e}"))
}

/// `dir` icermeginin bulundugu bolumun kullanim durumu.
pub fn disk_usage(dir: &str) -> Result<DiskUsage, String> {
    let path = Path::new(dir);
    let total = fs2::total_space(path).map_err(|e| e.to_string())?;
    let free = fs2::available_space(path).map_err(|e| e.to_string())?;
    Ok(DiskUsage {
        mount: dir.to_string(),
        total,
        free,
        used: total.saturating_sub(free),
    })
}

/* ---------- Otomatik baslatma (A6) ---------- */

/// Windows'ta acilista calistirma degerinin yazildigi anahtar.
pub const AUTOSTART_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";

/// Anahtardaki deger adi. Kurulum paketi de ayni adi kullanir; degistirilirse
/// uygulama ile kurulum birbirini tanimaz.
pub const AUTOSTART_VALUE: &str = "Serene";

/// Run degerinin icerigi: tirnakli mutlak yol.
///
/// Tirnak sart: bosluk iceren bir yol (`C:\Program Files\Serene\Serene.exe`)
/// tirnaksiz yazilirsa Windows komutu iki parcaya boler ve uygulama hic
/// baslamaz. Ayrica deger boslukla baslamazsa komut satiri olarak da
/// yorumlanabilir; tirnak ikisini birden engeller.
///
/// SOZLESME: NSIS kurulum paketi (sonraki faz) bu degeri ayni bicimde yazar.
/// Iki taraf ayri surumlendigi icin degisiklikte ikisi birlikte guncellenmeli;
/// aksi halde kurulumdan gelen Serene.exe kullaniciyi uygulamaz, ya da
/// Ayarlar'dan kapatilan bir kayit kurulumda yeniden yazilir.
pub fn run_value(command: &Path) -> String {
    format!("\"{}\"", command.display())
}

/// Otomatik baslatma acik mi?
///
/// Windows: `HKCU\...\Run` altinda `Serene` degeri aranir. Anahtar ya da
/// deger yoksa (hicbir sey kayitli degildir) `false` doner; deger okunamazsa
/// hata konsola dusurulur, cunku "kapali" demek yanlis bilgi olur.
#[cfg(windows)]
pub fn autostart_enabled() -> bool {
    use std::io;

    let root = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER);
    match root.open_subkey(AUTOSTART_KEY) {
        Ok(key) => key.get_value::<String, _>(AUTOSTART_VALUE).is_ok(),
        Err(err) if err.kind() == io::ErrorKind::NotFound => false,
        Err(err) => {
            eprintln!("[otomatik baslatma] {AUTOSTART_KEY} okunamadi: {err}");
            false
        }
    }
}

/// Otomatik baslatmayi acar ya da kapatir.
///
/// Windows: `true` degerin yazilmasini, `false` degerin silinmesini yapar.
/// Deger zaten yoksa silme basarili sayilir - istenen durum zaten saglanmistir.
#[cfg(windows)]
pub fn set_autostart(enabled: bool) -> std::io::Result<()> {
    use std::io;

    let root = winreg::RegKey::predef(winreg::enums::HKEY_CURRENT_USER);
    if enabled {
        let exe = std::env::current_exe()?;
        let (key, _disposition) = root.create_subkey(AUTOSTART_KEY)?;
        key.set_value(AUTOSTART_VALUE, &run_value(&exe))?;
        return Ok(());
    }

    let key = match root.open_subkey(AUTOSTART_KEY) {
        Ok(key) => key,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(err) => return Err(err),
    };
    match key.delete_value(AUTOSTART_VALUE) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(err),
    }
}

/// Bu isletim sisteminde otomatik baslatma desteklenmiyor; ayar degisimi
/// yalnizca oturum ici kalir, bu yuzden islem yok sayilir.
#[cfg(not(windows))]
pub fn autostart_enabled() -> bool {
    false
}

/// Bu isletim sisteminde otomatik baslatma desteklenmiyor; degistirmek
/// mumkun olmadigi icin hata da donulmez.
#[cfg(not(windows))]
pub fn set_autostart(_enabled: bool) -> std::io::Result<()> {
    Ok(())
}
