//! Uygulama surumunu Flutter paketinden (`pubspec.yaml`) Rust tarafina gomer.
//!
//! `core/build.rs` ile ayni isi yapar; ayri bir crate oldugu icin (ve
//! `core` build script'i calistirilmayan bagimliliklarda otomatik
//! yuklenmedigi icin) burada da gerekir. Ikisi ayni kaynaktan okur, bu yuzden
//! degerler ayrisamaz.
//!
//! Yol burada daha kisa: bu crate `flutter_app/rust/` altinda, yani
//! `pubspec.yaml` bir seviye yukarida.

use std::path::Path;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let pubspec = Path::new(&manifest_dir).join("..").join("pubspec.yaml");

    if !pubspec.is_file() {
        println!("cargo:warning=serene: pubspec.yaml bulunamadi, surum crate surumunde kalir");
        return;
    }
    println!("cargo:rerun-if-changed={}", pubspec.display());

    let text = std::fs::read_to_string(&pubspec).expect("pubspec okunamadi");
    for line in text.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("version:") {
            let version = rest.trim().trim_matches('"').trim_matches('\'');
            if !version.is_empty() {
                println!("cargo:rustc-env=SERENE_VERSION={version}");
                return;
            }
        }
    }
    println!("cargo:warning=serene: pubspec.yaml icinde version satiri yok");
}
