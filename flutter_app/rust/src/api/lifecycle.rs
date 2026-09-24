//! Motorun yasam dongusu cagrilarini Dart'a acar.

use serene_core::bridge;

use crate::state;

/// FRB kutuphanesinin bir kez calisan girisi: Rust panic'lerini Dart'a
/// tasimadan once loglanabilir kilar.
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Cekirdek motoru kurar: gorev deposu, ticker, pano yoklayici ve yerel kopru.
/// Ana pencere disindaki sureciler (onay penceresi) bunu cagirmaz.
pub async fn boot_engine() -> Result<(), String> {
    state::boot()?;
    Ok(())
}

/// Kapanirken yerel kopru kaydini (`ipc.json`) siler. Kalan dosya, tarayici
/// yanlislikla kapali bir uygulamaya baglanmaya calistirir.
#[flutter_rust_bridge::frb(sync)]
pub fn stop_bridge() {
    if let Ok(core) = state::core() {
        bridge::cleanup(core.bridge.path());
    }
}

/// Derlenen motor kutuphanesinin surumu; kopru yoklamasi bunu dogrular.
#[flutter_rust_bridge::frb(sync)]
pub fn engine_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}
