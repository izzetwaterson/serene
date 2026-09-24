//! FFI kabugunun tek motor ornegi.
//!
//! Tauri kabugunda bu isi `app.manage()` goruyordu; burada `OnceLock` var.
//! Motor yalnizca ana pencere icin kurulur: "Indirme Bilgileri" gibi ikinci
//! bir surec ayni tasks.json uzerine ikinci bir motor dikemez.

use std::sync::{Arc, Mutex, OnceLock};

use serene_core::bridge::{self, Bridge};
use serene_core::bus::EventBus;
use serene_core::clipboard;
use serene_core::manager::DownloadManager;
use serene_core::runtime;

pub(crate) struct Core {
    pub bus: EventBus,
    pub manager: Arc<DownloadManager>,
    pub bridge: Arc<Bridge>,
}

static CORE: OnceLock<Result<Core, String>> = OnceLock::new();
/// Es zamanli iki `boot` cagirisinin iki motor kurmasini engeller.
static BOOT_LOCK: Mutex<()> = Mutex::new(());

fn describe(err: impl std::fmt::Display) -> String {
    err.to_string()
}

fn build() -> Result<Core, String> {
    let bus = EventBus::new();
    let manager = DownloadManager::new(bus.clone()).map_err(describe)?;
    // Kabugun ipliği bir calisma zamani tasimaz; kopru kendi havuzumuzda kurulur.
    let bridge = runtime::block_on(bridge::start(bus.clone(), Arc::clone(&manager)))
        .map_err(describe)?;

    DownloadManager::spawn_ticker(Arc::clone(&manager));
    clipboard::spawn_watcher(bus.clone(), manager.clipboard_flag());
    manager.pump();

    Ok(Core { bus, manager, bridge })
}

/// Motoru en fazla bir kez kurar; sonraki cagrilar hazir kopyayi doner.
pub(crate) fn boot() -> Result<&'static Core, String> {
    let _guard = BOOT_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if CORE.get().is_none() {
        let _ = CORE.set(build());
    }
    core()
}

/// Yalnizca kurulmus motoru verir. Bir cagri asla kendiliginden motor
/// kurmaz: ikinci bir surecin ayni tasks.json'a yerlesmesini engellemek icin
/// once `boot_engine` sart.
pub(crate) fn core() -> Result<&'static Core, String> {
    match CORE.get() {
        Some(Ok(core)) => Ok(core),
        Some(Err(err)) => Err(err.clone()),
        None => Err("Motor baslatilmadi".into()),
    }
}
