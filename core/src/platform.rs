//! Isletim kabigi: dosya acma/gosterme ve disk kullanimi.
//!
//! Arayuzden bagimsiz olduklari icin motorla birlikte burada yasiyorlar;
//! her kabuk ayni davranisi tekrar yazmak zorunda kalmiyor.

use std::path::Path;
use std::process::Command;

use crate::models::DiskUsage;

pub fn reveal_path(path: &Path) -> Result<(), String> {
    // Explorer `/select,` ifadesini tek argüman olarak bekler; path icinde tirnak
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

/// `dir` icermeginin bulundugu bolümün kullanim durumu.
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
