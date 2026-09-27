//! Surumu `pubspec.yaml`'dan okur ve Rust tarafina gomer.
//!
//! Neden gerekli: uygulamanin surumu Flutter paketinde yasar (`pubspec.yaml`,
//! Faz 3'te tek kaynak olarak secildi) ve Rust tarafinda ayri bir surum
//! tutuluyordu (`CARGO_PKG_VERSION` = 0.1.0). Iki deger zamanla ayrisir ve
//! ayarlarda gosterilen surum **yanlis** olur. Burada tek dogruluk kaynagi
//! Flutter paketidir; crate surumu yalnizca gelistirme icindir.
//!
//! `flutter_app/rust` ve `core` bu degeri `env!("SERENE_VERSION")` ile okur.
//! `flutter_app/rust/pubspec.yaml` yolunu `../../pubspec.yaml` ile verir; bu
//! crate `core` icinde degilse yol farklidir, o durumda build uyarisi verilir
//! ve surum crate surumune duser (cok yanlis degil, ama ozellikle bildirilir).

use std::path::Path;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    // `CARGO_MANIFEST_DIR` bu build.rs'in ait oldugu crate'in kokudur:
    //   core/               -> ../flutter_app/pubspec.yaml
    //   flutter_app/rust/   -> ../pubspec.yaml
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let manifest = Path::new(&manifest_dir);

    let candidates = [
        manifest.join("..").join("flutter_app").join("pubspec.yaml"),
        manifest.join("..").join("pubspec.yaml"),
    ];

    for candidate in candidates.iter() {
        if !candidate.is_file() {
            continue;
        }
        println!("cargo:rerun-if-changed={}", candidate.display());
        let text = std::fs::read_to_string(candidate).expect("pubspec okunamadi");
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
        // version satiri yoksa yine de dosyayi izlemeye devam et.
        break;
    }

    // Buraya dusersek tek kaynak bulunamadi. Surum crate surumunde kalir ve
    // derleme sirasinda bir kez uyari basilir (hata degil: gelistirme icin
    // yeterli, ama ayarlarda gosterilen deger yanlis olabilir).
    println!("cargo:warning=serene: pubspec.yaml bulunamadi, surum crate surumunde kalir");
}
