//! Host kimligi sabitleri: Firefox, eklenti, ikili ve kurulum paketi arasindaki
//! sozlesme.
//!
//! Bu degerler tek tek kucuk ama cok baglayicidir. `HOST_NAME` degisirse
//! eklentinin `connectNative` cagrisi sessizce baglanmaz; `EXTENSION_ID`
//! degisirse Firefox manifesti reddeder ("Native host has not been registered
//! with the browser"); `REG_PATH` veya `NMH_EXE` degisirse kurulumdan gelen
//! kayit, uygulamanin yazdigi kaydi tanimaz. Hepsi calisma aninda degil, burada
//! kirilir.

use std::path::Path;

use serene_native_host::{EXTENSION_ID, HOST_NAME, NMH_EXE, REG_PATH};

/// Depo kokunden bir dosya; yalnizca *okunur*.
fn repo_file(relative: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join(relative);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{} okunamadi: {e}", path.display()))
}

#[test]
fn host_name_is_the_firefox_native_messaging_identifier() {
    // `runtime.connectNative("...")` degeriyle birebir ayni olmali.
    assert_eq!(HOST_NAME, "com.serene.nmh");

    // Firefox geri dongulu adi ister: noktali, kucuk harfli, bosluksuz.
    assert!(HOST_NAME.contains('.'), "noktali olmali: {HOST_NAME}");
    assert!(!HOST_NAME.contains(' '), "bosluk olmamali: {HOST_NAME}");
    assert_eq!(HOST_NAME, HOST_NAME.to_lowercase(), "kucuk harf olmali");
    assert!(!HOST_NAME.starts_with('.'), "noktayla baslamamali");
    assert!(!HOST_NAME.ends_with('.'), "noktayla bitmemeli");
    assert!(
        HOST_NAME.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-'),
        "yalnizca harf/rakam/nokta/tire izin var: {HOST_NAME}"
    );
}

#[test]
fn extension_id_is_a_stable_gecko_id() {
    // `extension/manifest.json` -> `browser_specific_settings.gecko.id`.
    assert_eq!(EXTENSION_ID, "serene@izzet.local");

    // Gecko kimligi `ad@alan` biciminde olmali; sadece gorunum degil,
    // Firefox imzali eklenti kimligini bu bicimden turetir.
    let (local, domain) = EXTENSION_ID
        .split_once('@')
        .unwrap_or_else(|| panic!("@ yok: {EXTENSION_ID}"));
    assert!(!local.is_empty() && !domain.is_empty(), "iki taraf da dolu olmali");
    assert!(domain.contains('.'), "alan adi noktali olmali: {domain}");
    assert!(EXTENSION_ID.is_ascii(), "ASCII olmali");
    assert!(!EXTENSION_ID.contains(' '), "bosluk olmamali");
}

#[test]
fn registry_path_is_under_the_current_user_mozilla_key() {
    // check_nmh.mjs ve NSIS kurulum paketi de bu yolu yaziyor. Tam yol:
    // HKCU\Software\Mozilla\NativeMessagingHosts\com.serene.nmh
    assert_eq!(
        REG_PATH,
        r"Software\Mozilla\NativeMessagingHosts\com.serene.nmh"
    );

    // Anahtar, yerel makine veya sinif kaydinda degil kullanici kaydinda;
    // yol kovasi (drive harfi) icermemeli, `HKCU\` on eki de icermemeli.
    assert!(!REG_PATH.contains(':'), "kovas yolu olmamali: {REG_PATH}");
    assert!(!REG_PATH.to_uppercase().contains("HKCU"), "on ek tekrarlanmamali");

    // Anahtarin adi host adiyla ayni olmali, yoksa Firefox manifesti bulamaz.
    let leaf = REG_PATH.rsplit('\\').next().expect("anahtar adi");
    assert_eq!(leaf, HOST_NAME);

    // Mozilla'nin native messaging anahtari dogru kokte.
    assert!(REG_PATH.starts_with(r"Software\Mozilla\NativeMessagingHosts\"));
}

#[test]
fn exe_name_matches_the_bin_target_of_this_crate() {
    // Yayindaki dosya adi `serene-nmh.exe`; manifest bu adresi gostermezse
    // Firefox kaydi olsa bile host'u baslatamaz.
    assert_eq!(NMH_EXE, "serene-nmh.exe");
    assert!(NMH_EXE.ends_with(".exe"), "Windows uzantisi zorunlu: {NMH_EXE}");

    // Ikili gercekten bu adiyla uretiliyor mu? `[[bin]]` bolumunden oku.
    let toml = repo_file("native-host/Cargo.toml");
    let mut in_bin = false;
    let mut bin_name = None;
    for line in toml.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_bin = line == "[[bin]]";
            continue;
        }
        if !in_bin {
            continue;
        }
        if let Some(rest) = line.strip_prefix("name") {
            let Some(rest) = rest.trim_start().strip_prefix('=') else {
                continue;
            };
            bin_name = Some(
                rest.trim()
                    .trim_matches('"')
                    .split('#')
                    .next()
                    .unwrap_or_default()
                    .trim()
                    .to_string(),
            );
            break;
        }
    }
    let bin_name = bin_name.expect("Cargo.toml'da [[bin]] adi olmali");
    assert_eq!(
        format!("{bin_name}.exe"),
        NMH_EXE,
        "ikili adi ile manifestteki ad ayri surumde degismis"
    );
}

#[test]
fn extension_manifest_declares_the_same_extension_id() {
    // Asil sozlesme: manifestteki `gecko.id` ile `EXTENSION_ID` ayni olmali.
    // Farkli olursa Firefox host'u "izin yok" diye reddeder.
    let text = repo_file("extension/manifest.json");
    let value: serde_json::Value = serde_json::from_str(&text).expect("gecerli manifest JSON");

    let gecko = &value["browser_specific_settings"]["gecko"];
    assert_eq!(
        gecko["id"].as_str().expect("gecko.id"),
        EXTENSION_ID,
        "eklenti kimligi ile manifestin allowed_extensions listesi uyusmali"
    );

    // Bu eslesme olmazsa host'a hic ulasilamaz: izin de olmali.
    let permissions = value["permissions"]
        .as_array()
        .expect("permissions dizisi")
        .iter()
        .filter_map(|item| item.as_str())
        .collect::<Vec<_>>();
    assert!(
        permissions.contains(&"nativeMessaging"),
        "nativeMessaging izni yok: {permissions:?}"
    );
}

#[test]
fn extension_background_connects_using_the_same_host_name() {
    // `browser.runtime.connectNative(HOST_NAME)` icin kullanilan sabit
    // bizimkiyle ayni olmali. Sabitin Rust tarafinda ad degistirmesi
    // calismaz; burada satiri okuyup degeri karsilastiriyoruz.
    let js = repo_file("extension/background.js");

    let mut declared: Option<(String, String)> = None;
    for line in js.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix("const ") else {
            continue;
        };
        let Some((name, value)) = rest.split_once('=') else {
            continue;
        };
        let Some(value) = value.trim().trim_matches('"').split('"').next() else {
            continue;
        };
        let name = name.trim();
        if js.contains(&format!("connectNative({name})")) {
            declared = Some((name.to_string(), value.to_string()));
            break;
        }
    }

    let (variable, value) = declared.expect("connectNative ile kullanilan bir const olmali");
    assert_eq!(
        value, HOST_NAME,
        "{variable} degeri host adiyla uyusmali (background.js)"
    );
}
