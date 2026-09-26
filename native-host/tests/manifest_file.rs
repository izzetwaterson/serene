//! Diskteki host manifesti ve yol cozumleme.
//!
//! Manifest, Firefox'un tek baktigi dosya: yanlis bir alan (mesela `type`
//! yerine `kind`) host'un sessizce calismaz olmasina yol acar. Buradaki
//! testler yalnizca gecici klasore yazar; `%APPDATA%\Serene` hic dokunulmaz.

use std::path::{Path, PathBuf};

use serene_native_host::{
    build_manifest, data_dir_in, log_path_in, manifest_json, manifest_path, manifest_path_in,
    nmh_dir_in, nmh_exe_from, nmh_exe_path, registry_value, write_manifest_to, HostManifest,
    EXTENSION_ID, HOST_NAME, NMH_EXE,
};

/// Test basina ayri, surec kimligine gore benzersiz klasor. `Drop` ile
/// silinir; `tempfile` bagimliligi yok.
struct Scratch(PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("serene-nmh-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("gecici klasor");
        Self(dir)
    }

    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }

    /// Klasorde kalan dosya adlari, sirali.
    fn names(&self) -> Vec<String> {
        let mut names = std::fs::read_dir(&self.0)
            .expect("klasor okunmali")
            .map(|entry| {
                entry
                    .expect("kayit")
                    .file_name()
                    .to_string_lossy()
                    .to_string()
            })
            .collect::<Vec<_>>();
        names.sort();
        names
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn parse(text: &str) -> serde_json::Value {
    serde_json::from_str(text).expect("gecerli JSON")
}

fn keys(value: &serde_json::Value) -> Vec<String> {
    let mut names = value
        .as_object()
        .expect("nesne")
        .keys()
        .map(|key| key.to_string())
        .collect::<Vec<_>>();
    names.sort();
    names
}

/* ---------- HostManifest serilestirme ---------- */

#[test]
fn manifest_has_exactly_the_fields_firefox_requires() {
    // Firefox `name`, `description`, `path`, `type`, `allowed_extensions`
    // bekler. Eksik alan host'i reddeder, fazladan alan zarari yoktur ama
    // sozlesmeyi bozmamalidir; ikisi de sabitleniyor.
    let json = manifest_json(&build_manifest(Path::new(r"C:\app\serene-nmh.exe"))).expect("JSON");
    let value = parse(&json);

    assert_eq!(
        keys(&value),
        vec![
            "allowed_extensions".to_string(),
            "description".to_string(),
            "name".to_string(),
            "path".to_string(),
            "type".to_string(),
        ]
    );

    // `kind` alani `type` olarak yeniden adlandirilir. Yeniden adlandirma
    // kalkarsa burasi sessizce kirmizi olur.
    assert!(
        value.get("kind").is_none(),
        "Rust alani `kind`, JSON'da `type` olmali"
    );
    assert_eq!(value["type"].as_str(), Some("stdio"));
    assert_eq!(value["name"].as_str(), Some(HOST_NAME));
    assert!(!value["description"]
        .as_str()
        .expect("aciklama")
        .is_empty());
}

#[test]
fn manifest_allows_only_the_serene_extension() {
    // izin listesi tek eleman: eklentinin gecko.id'si. Bos liste veya yanlis
    // kimlik, baglantiyi reddedilmis kilar.
    let manifest = build_manifest(Path::new(r"C:\app\serene-nmh.exe"));
    assert_eq!(manifest.allowed_extensions, vec![EXTENSION_ID.to_string()]);

    let json = manifest_json(&manifest).expect("JSON");
    let value = parse(&json);
    let allowed = value["allowed_extensions"]
        .as_array()
        .expect("dizi")
        .iter()
        .map(|item| item.as_str().expect("metin").to_string())
        .collect::<Vec<_>>();
    assert_eq!(allowed, vec![EXTENSION_ID.to_string()]);
}

#[test]
fn manifest_points_at_the_nmh_executable() {
    // `path` dogrudan calistirilacak dosyadir: tirnak, arguman ya da gecici
    // yol olmamali. Bosluk iceren yol olsa bile oldugu gibi yazilir.
    let exe = Path::new(r"C:\Program Files\Serene\serene-nmh.exe");
    let manifest = build_manifest(exe);
    assert_eq!(manifest.path, exe.to_string_lossy());
    assert!(manifest.path.ends_with(NMH_EXE), "{}", manifest.path);
    assert!(!manifest.path.contains('"'), "tirnak olmamali");

    let json = manifest_json(&manifest).expect("JSON");
    assert_eq!(parse(&json)["path"].as_str(), Some(exe.to_string_lossy().as_ref()));
}

#[test]
fn manifest_round_trips_through_json() {
    // `register` okumuyor, ama Firefox ve `check_nmh.mjs` okuyor: yazilan
    // sekli ayni tipten geri gelmeli.
    let manifest = build_manifest(Path::new(r"C:\app\serene-nmh.exe"));
    let json = manifest_json(&manifest).expect("JSON");
    let back: HostManifest = serde_json::from_str(&json).expect("geri okunmali");
    assert_eq!(back.name, manifest.name);
    assert_eq!(back.description, manifest.description);
    assert_eq!(back.path, manifest.path);
    assert_eq!(back.kind, manifest.kind);
    assert_eq!(back.allowed_extensions, manifest.allowed_extensions);
}

#[test]
fn manifest_json_is_pretty_printed_for_hand_inspection() {
    // `register` `to_string_pretty` kullanir: dosya kullaniciya da gorunur.
    // Tek satirlik JSON'i okumak zor olurdu; bicim sessizce degismemeli.
    let json = manifest_json(&build_manifest(Path::new(r"C:\app\serene-nmh.exe"))).expect("JSON");
    assert!(json.contains("\n  \"name\""), "girintili yazilmali: {json}");
    assert!(json.ends_with('}'), "son satir nesneyi kapatmali");
}

#[test]
fn write_manifest_to_creates_exactly_one_file_in_the_given_dir() {
    // Yan etki testi: verilen klasor disinda hicbir sey yazilmaz. Kayit
    // defteri bu adimin icinde degildir (bkz. `registration_steps.rs`).
    let scratch = Scratch::new("write");
    let dir = scratch.path("nmh");
    let exe = scratch.path("serene-nmh.exe");
    std::fs::write(&exe, b"sahte ikili").expect("sahte ikili");

    let path = write_manifest_to(&dir, &exe).expect("manifest yazilmali");

    assert_eq!(path, dir.join(format!("{HOST_NAME}.json")));
    assert!(path.exists());
    // Klasor kendisi de yaratildi (yuklemede yoktu), fazladan dosya yok.
    assert_eq!(scratch.names(), vec!["nmh".to_string(), "serene-nmh.exe".to_string()]);

    let text = std::fs::read_to_string(&path).expect("manifest okunmali");
    let value = parse(&text);
    assert_eq!(value["name"].as_str(), Some(HOST_NAME));
    assert_eq!(value["type"].as_str(), Some("stdio"));
    assert_eq!(value["path"].as_str(), Some(exe.to_string_lossy().as_ref()));

    // Ikinci yazim ayni dosyayi gunceller, yeni dosya dogmaz.
    let again = write_manifest_to(&dir, &exe).expect("yeniden yazim");
    assert_eq!(again, path);
    assert_eq!(scratch.names().len(), 2);
}

/* ---------- yol cozumleme ---------- */

#[test]
fn paths_are_composed_under_one_base() {
    // Turetilmis yollar tek bir kokten cikar: Serene\nmh\<host>.json
    let base = Path::new(r"C:\Users\ornek\AppData\Roaming");
    assert_eq!(data_dir_in(base), base.join("Serene"));
    assert_eq!(nmh_dir_in(&data_dir_in(base)), base.join("Serene").join("nmh"));
    assert_eq!(
        manifest_path_in(base),
        base.join("Serene").join("nmh").join(format!("{HOST_NAME}.json"))
    );
    assert_eq!(
        log_path_in(base),
        base.join("Serene").join("nmh").join("register.log")
    );

    // Manifest dosya adi host adiyla ayni olmali, yoksa Firefox kaydi okumaz.
    assert_eq!(
        manifest_path_in(base).file_name().and_then(|n| n.to_str()),
        Some("com.serene.nmh.json")
    );
    // Kayit defterindeki deger bu dosyayi gosterir: ayni yol.
    assert_eq!(
        registry_value(&manifest_path_in(base)),
        format!(
            r"{}\Serene\nmh\{HOST_NAME}.json",
            base.display()
        )
    );
}

#[test]
fn live_paths_are_consistent_with_each_other() {
    // Yalnizca *okuma*: hicbir dosya olusturulmaz, hicbir sey silinmez.
    // Gercek konum makineye gore degisir; sadece birbirleriyle tutarli olmasi
    // ve dosya adlarinin dogru olmasi dogrulanir.
    let manifest = manifest_path();
    assert_eq!(
        manifest.file_name().and_then(|n| n.to_str()),
        Some("com.serene.nmh.json")
    );
    let dir = manifest.parent().expect("nmh klasoru");
    assert_eq!(dir.file_name().and_then(|n| n.to_str()), Some("nmh"));
    assert_eq!(
        dir.parent()
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str()),
        Some("Serene")
    );
    assert!(manifest.is_absolute(), "goreli yol kayit defterine yazilamaz");

    // Gunluk ayni klasorde, ayri bir dosya.
    let log = log_path_in(dir.parent().unwrap().parent().unwrap());
    assert_eq!(log.parent(), Some(dir));
    assert_eq!(log.file_name().and_then(|n| n.to_str()), Some("register.log"));
}

#[test]
fn nmh_exe_is_the_sibling_of_the_running_executable() {
    // Saf kism: calisan ikilinin yolundan kardes yolu turetiliyor.
    let exe = Path::new(r"C:\Program Files\Serene\Serene.exe");
    assert_eq!(
        nmh_exe_from(exe).expect("yol"),
        Path::new(r"C:\Program Files\Serene\serene-nmh.exe")
    );

    // Govde adindan cagrildiginda kardes yoktur, ayni yer.
    assert_eq!(
        nmh_exe_from(Path::new("Serene.exe")).expect("yol"),
        Path::new("serene-nmh.exe")
    );
    // Kok dizin (`C:\`) icin klasor yoktur: anlamli bir hata.
    #[cfg(windows)]
    {
        let err = nmh_exe_from(Path::new(r"C:\")).expect_err("hata donmeli");
        assert_eq!(err, "Ikili klasoru bulunamadi");
    }
}

#[test]
fn nmh_exe_path_of_this_process_resolves_next_to_the_test_binary() {
    // `nmh_exe_path` calisan surece bagli oldugu icin yalnizca burada
    // calisabilir: donen yol test ikilisinin yanindaki `serene-nmh.exe`
    // olmali. (Test kosumunda o dosya yok; `register` bu yuzden "yok" hatasi
    // verir - dogru davranis, `registration_steps.rs`'de pinleniyor.)
    let current = std::env::current_exe().expect("calisan yol bilinmeli");
    let resolved = nmh_exe_path().expect("yol cozumlenmeli");

    assert_eq!(resolved, nmh_exe_from(&current).expect("yol"));
    assert_eq!(
        resolved.file_name().and_then(|n| n.to_str()),
        Some(NMH_EXE)
    );
    assert_eq!(resolved.parent(), current.parent());
    assert!(resolved.is_absolute(), "goreli yol manifeste yazilamaz");
}
