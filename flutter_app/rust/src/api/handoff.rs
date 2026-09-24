//! "İndirme Bilgileri" penceresinin calisan ornekle konusmasi.
//!
//! Onay penceresi ayri bir surectir ve kendi motorunu kurmaz: iki surec ayni
//! gorev listesine yazamaz. Bunun yerine `ipc.json`'daki yerel kopru uzerinden
//! calisan ornegin motoruna komut yollar.

use serene_core::bridge;

/// Karar: kayit yeri ve ad ayarlanir (gorev boylece onaylanmis olur),
/// `start` ise indirmeyi hemen kuyruga alir.
#[flutter_rust_bridge::frb(sync)]
pub fn confirm_handoff(
    id: String,
    dest_dir: String,
    filename: String,
    start: bool,
) -> Result<(), String> {
    bridge::handoff_confirm(&id, &dest_dir, &filename, start)
}

/// Karar yok: devralma listeden cikarilir, inen dosyaya dokunulmaz.
#[flutter_rust_bridge::frb(sync)]
pub fn cancel_handoff(id: String) -> Result<(), String> {
    bridge::handoff_cancel(&id)
}
