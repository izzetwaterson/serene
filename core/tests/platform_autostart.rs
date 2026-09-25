//! Otomatik baslatma yolunun saf kisimi: Run degerinin icerigi ve
//! deger/anahtar adlari.
//!
//! Kayit defteri yazimi burada bilerek denenmez: `HKCU\...\Run` gelistirici
//! makinesinin gercek durumunu degistirir, testin isi degil. Test edilebilen
//! kisim degerin nasil kuruldugu: yolun tirnaklanmasi, deger adi ve anahtar
//! yolu. Windows tarafinda ayrica yalnizca *okuma* dener.

use std::path::Path;

use serene_core::platform::{run_value, AUTOSTART_KEY, AUTOSTART_VALUE};

#[test]
fn run_value_quotes_the_executable_path() {
    // Bosluk iceren yol tirnaksiz yazilirsa Windows komutu iki parcaya
    // boler ve uygulama hic baslamaz.
    let exe = Path::new(r"C:\Program Files\Serene\Serene.exe");
    assert_eq!(run_value(exe), r#""C:\Program Files\Serene\Serene.exe""#);
}

#[test]
fn run_value_wraps_even_a_bare_executable_name() {
    // Tirnak her zaman eklenir: deger boslukla basliyorsa komut satiri
    // yorumu devreye girsin.
    assert_eq!(run_value(Path::new("Serene.exe")), r#""Serene.exe""#);
}

#[test]
fn run_value_of_the_running_executable_is_absolute() {
    let exe = std::env::current_exe().expect("calisan yol bilinmeli");
    assert!(exe.is_absolute(), "goreli yol Run degerine yazilmaz");
    let value = run_value(&exe);
    assert_eq!(value, format!("\"{}\"", exe.display()));
    assert!(value.starts_with('"') && value.ends_with('"'), "{value}");
}

#[test]
fn registry_location_matches_the_installer_contract() {
    // NSIS paketi bu anahtari ve bu deger adini yaziyor; biri degisirse
    // uygulama ile kurulum birbirini tanimaz.
    assert_eq!(
        AUTOSTART_KEY,
        r"Software\Microsoft\Windows\CurrentVersion\Run"
    );
    assert_eq!(AUTOSTART_VALUE, "Serene");
}

#[cfg(not(windows))]
#[test]
fn autostart_is_a_noop_off_windows() {
    // Desteklenmeyen isletim sisteminde hata da donulmez: ayar kutusu
    // degisse bile uygulama acilir.
    assert!(serene_core::platform::set_autostart(true).is_ok());
    assert!(serene_core::platform::set_autostart(false).is_ok());
    assert!(!serene_core::platform::autostart_enabled());
}

#[cfg(windows)]
#[test]
fn autostart_can_be_read_without_changing_anything() {
    // Yalnizca okuma: gelistirici makinesindeki kayit bozulmaz. Sonuc
    // ne olursa olsun test, ayar dogru yaziliyorsa degerin calisan yolun
    // tirnakli hali oldugunu dogrulayamaz (kurulmus bir Serene farkli bir
    // yoldan gelir), bu yuzden yalnizca panik etmedigi dogrulanir.
    let _ = serene_core::platform::autostart_enabled();
}
