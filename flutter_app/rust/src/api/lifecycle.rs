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

/// Calisan bir Serene ornegi varsa penceresini one getirir ve `true` doner.
/// Cagiran taraf o zaman kendi motorunu kurmadan cikmali; iki surec ayni
/// tasks.json'a yazmasin.
#[flutter_rust_bridge::frb(sync)]
pub fn hand_off_to_running() -> bool {
    bridge::notify_running("show")
}

/// Firefox native messaging kaydini tazele; ikilinin yolunu kaydeder.
/// `--selfcheck` ve gelistirme derlemesi bu cagriya hic bakmaz, boylece
/// kosumlar kullaniciyin tarayici kaydiyla oynamiyor.
#[flutter_rust_bridge::frb(sync)]
pub fn register_browser_host() -> Result<String, String> {
    serene_native_host::register()
        .map(|path| path.to_string_lossy().into_owned())
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

/// Uygulamanin surumu. Ayarlar penceresinde gosterilir.
///
/// `core/build.rs` bunu `pubspec.yaml`'dan okuyup gomuyor; boylece surumun tek
/// dogruluk kaynagi Flutter paketi kalir (Faz 3 karari). `CARGO_PKG_VERSION`
/// burada **kullanilmaz**: o deger motor crate'inin surumudur (0.1.0) ve
/// ayarlarda gosterilen degerle karistirilirsa kullanici yanlis bilgi gorur.
#[flutter_rust_bridge::frb(sync)]
pub fn app_version() -> String {
    option_env!("SERENE_VERSION")
        .unwrap_or(env!("CARGO_PKG_VERSION"))
        .to_owned()
}

/// Bir adresi varsayilan tarayicida acar (Ayarlar > Hakkinda > Kaynak kodu).
///
/// Neden `url_launcher` degil: o paket ek bagimlilik ve bir platform eklentisi
/// getirir. Buradaki tek ihtiyac "bu adresi kullanilabilir bir sekilde ac" —
/// Windows'ta bunu `cmd /c start` zaten yapar, tarayici zaten varsayilan
/// olarak kayitlidir. Dogrudan Rust tarafinda birkac satirlik is; yeni paket yok.
///
/// Yalnizca `https://` ve `http://` kabul edilir; boylece komut satiri
/// enjeksiyonuyla rastgele bir komut calistirilamaz.
#[flutter_rust_bridge::frb(sync)]
pub fn open_external(url: String) -> Result<(), String> {
    let trimmed = url.trim();
    if !(trimmed.starts_with("https://") || trimmed.starts_with("http://")) {
        return Err("yalnizca http(s) adresleri acilabilir".into());
    }
    if trimmed.contains(['"', '\n', '\r']) {
        return Err("gecersiz adres".into());
    }

    // `start` sonraki tirnaki arguman olarak yutar; `cmd /c` teshis
    // penceresi acmamasi icin bos gosterilir.
    let status = std::process::Command::new("cmd")
        .args(["/c", "start", "", trimmed])
        .status();

    match status {
        Ok(s) if s.success() => Ok(()),
        Ok(s) => Err(format!("tarayici acilmadi: {}", s)),
        Err(e) => Err(format!("tarayici acilamadi: {e}")),
    }
}
