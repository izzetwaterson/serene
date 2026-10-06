//! Ayri indirme penceresinin calisan ornekle konusmasi.
//!
//! Onay penceresi gibi bu pencere de ayri bir surectir ve kendi motorunu
//! kurmaz: gorevi ve komutlari `ipc.json`'daki yerel kopru uzerinden okur.

use serene_core::bridge;

use crate::api::dto::Task;

/// Tek gorevin (parcalariyla) guncel hali; listede yoksa `None`.
pub fn task_snapshot(id: String) -> Result<Option<Task>, String> {
    Ok(bridge::task_snapshot(&id)?.map(Task::from))
}

/// Ilerlemeyi duraklatir.
pub async fn task_pause(id: String) -> Result<(), String> {
    bridge::task_pause(&id)
}

/// Duraklatilmis indirmeye devam eder.
pub async fn task_resume(id: String) -> Result<(), String> {
    bridge::task_resume(&id)
}

/// Indirmeyi listeden cikarir (inen dosyaya dokunmaz).
pub async fn task_remove(id: String) -> Result<(), String> {
    bridge::task_remove(&id)
}
