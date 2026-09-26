//! Kayit kararlarinin saf kismi: ne yazilir, ne silinir, ne zaman hata doner.
//!
//! Bu dosya bilerek `register`/`unregister` cagirmaz. Ikisi de gercek
//! makine durumunu degistirir: `register` `HKCU\Software\Mozilla\...`
//! anahtarini yazar, `unregister` siler; ikisi de
//! `%APPDATA%\Serene\nmh\com.serene.nmh.json` dosyasini yazar ya da siler.
//! Gelistirici makinesinde calisan bir test bunu yapmaz. Test edilebilen
//! kisim kararin kendisi: `RegisterStep` / `UnregisterStep` hangi yola girildigini
//! ve ne yazilacagini belirler, yan etkileri `register`/`unregister` yapar.

use std::path::{Path, PathBuf};

use serene_native_host::{
    build_manifest, log_line, manifest_json, registry_step, registry_value, registration_is_usable,
    verification_step, write_manifest_to, RegisterStep, UnregisterStep, EXTENSION_ID, HOST_NAME,
    NMH_EXE,
};

/// Test basina ayri, surec kimligine gore benzersiz klasor. `Drop` ile
/// silinir; `tempfile` bagimliligi yok.
struct Scratch(PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("serene-nmh-reg-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("gecici klasor");
        Self(dir)
    }

    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/* ---------- register: kayit defterine yazilacak mi ---------- */

#[test]
fn registry_is_written_when_there_is_no_value_yet() {
    // Anahtar yoksa deger `None`: ilk kurulumda yazilir.
    let value = r"C:\Users\ornek\AppData\Roaming\Serene\nmh\com.serene.nmh.json";
    assert_eq!(
        registry_step(value, None),
        RegisterStep::NeedsRegistryWrite(value.to_string())
    );
    // Yazilacak adim gunluk yazmaz (dosya yazimi sonrasi bir sey olmamali).
    assert!(registry_step(value, None).log().is_none());
    assert!(registry_step(value, None).error().is_none());
}

#[test]
fn registry_is_rewritten_when_the_value_points_somewhere_else() {
    // Uygulama yeni bir klasore tasindiysa deger eskiyi gosterir; yazilmali.
    let value = r"C:\Yeni\Serene\nmh\com.serene.nmh.json";
    assert_eq!(
        registry_step(value, Some(r"C:\Eski\com.serene.nmh.json")),
        RegisterStep::NeedsRegistryWrite(value.to_string())
    );
}

#[test]
fn registry_is_left_alone_when_the_value_already_matches() {
    // Ayni yol: "Kayit zaten guncel". Gereksiz yazma, hem yavasiz hem de
    // gereksiz kayit defteri erisimi demek.
    let value = r"C:\Users\ornek\AppData\Roaming\Serene\nmh\com.serene.nmh.json";
    let step = registry_step(value, Some(value));
    assert_eq!(step, RegisterStep::AlreadyCurrent(value.to_string()));
    assert_eq!(
        step.log(),
        Some(format!("Kayit zaten guncel: {value}"))
    );
    assert!(step.error().is_none());
}

#[test]
fn registry_step_never_treats_an_empty_value_as_current() {
    // Bos deger hicbir yolu gostermez; "guncel" sayilmamali.
    let value = r"C:\app\com.serene.nmh.json";
    assert_eq!(
        registry_step(value, Some("")),
        RegisterStep::NeedsRegistryWrite(value.to_string())
    );
}

/* ---------- register: yazma sonrasi dogrulama ---------- */

#[test]
fn a_verified_write_reports_success() {
    let value = r"C:\app\com.serene.nmh.json";
    let step = verification_step(value, true);
    assert_eq!(step, RegisterStep::Registered(value.to_string()));
    assert_eq!(step.log(), Some(format!("Kayit yapildi: {value}")));
    assert!(step.error().is_none());
}

#[test]
fn a_write_that_cannot_be_read_back_is_an_error() {
    // Yetki yoksa ya da WOW64 yonlendirmesi olursa yazma sessizce basarisiz
    // olabilir. "Basarili" donmek, kullaniciya calismayan bir kayit birakir.
    let value = r"C:\app\com.serene.nmh.json";
    let step = verification_step(value, false);
    assert_eq!(step, RegisterStep::NotVerified(value.to_string()));
    assert_eq!(
        step.error(),
        Some("Kayit defteri yazildi ama dogrulanamadi".to_string())
    );
    assert_eq!(
        step.log(),
        Some("HATA: Kayit defteri yazildi ama dogrulanamadi".to_string())
    );
}

/* ---------- register: ikili eksik ---------- */

#[test]
fn a_missing_executable_is_reported_before_anything_is_written() {
    let exe = Path::new(r"C:\app\serene-nmh.exe");
    let step = RegisterStep::MissingExecutable(exe.to_path_buf());

    let error = step.error().expect("eksik ikili hatadir");
    assert_eq!(error, format!("{NMH_EXE} bulunamadi: {}", exe.display()));
    assert_eq!(step.log(), Some(format!("HATA: {error}")));
    // Hata mesaji ikilinin adini icermeli, yoksa kullanici ne arayacagini bilemez.
    assert!(error.contains(NMH_EXE), "{error}");

    // `register` bu adimda `error()`'in hep `Some` olduguna guvenir
    // (`expect`); bu varsayim sessizce bozulursa test kirmizi olmali.
    assert!(!RegisterStep::MissingExecutable(exe.to_path_buf())
        .error()
        .expect("hata")
        .is_empty());
}

#[test]
fn successful_register_steps_carry_no_error() {
    // `register` bu uc adimda hatayi `None` gorerek devam eder; biri hata
    // donmeye baslarsa kullaniciyi gereksiz yere engeller.
    for step in [
        RegisterStep::NeedsRegistryWrite(r"C:\a\com.serene.nmh.json".into()),
        RegisterStep::AlreadyCurrent(r"C:\a\com.serene.nmh.json".into()),
        RegisterStep::Registered(r"C:\a\com.serene.nmh.json".into()),
    ] {
        assert!(step.error().is_none(), "{step:?} hatasi olmamali");
    }
}

/* ---------- register: manifest once yazilir ---------- */

#[test]
fn the_manifest_is_written_before_the_registry_is_consulted() {
    // Siralama sozlesmesi: manifest *her zaman* yazilir; kayit defteri
    // "zaten guncel" olsa bile. Aksi halde indirilmis bir klasorde manifest
    // eksik kalir ve kayit guncel sanilir.
    //
    // Kayit defteri yazimi bu adimda yok; bu yuzden test yalnizca "once
    // yaz, sonra karar ver" yarimini, gecici klasorde dogrular.
    let scratch = Scratch::new("order");
    let dir = scratch.path("nmh");
    let exe = scratch.path(NMH_EXE);
    std::fs::write(&exe, b"sahte ikili").expect("sahte ikili");

    let path = write_manifest_to(&dir, &exe).expect("manifest yazilmali");
    let value = registry_value(&path);
    let step = registry_step(&value, None);

    assert_eq!(step, RegisterStep::NeedsRegistryWrite(value.clone()));
    // Karar verildiginde manifest gercekten diskte ve okunabilir.
    assert!(path.exists());
    let text = std::fs::read_to_string(&path).expect("manifest okunmali");
    let value_json: serde_json::Value = serde_json::from_str(&text).expect("JSON");
    assert_eq!(value_json["name"].as_str(), Some(HOST_NAME));
    assert_eq!(value, registry_value(&path));
}

/* ---------- unregister ---------- */

#[test]
fn deleting_the_key_also_removes_the_manifest() {
    let step = UnregisterStep::Removed;
    assert_eq!(step.log(), Some("Kayit silindi"));
    assert!(step.error().is_none());
    assert!(
        step.removes_manifest(),
        "anahtar silinince manifest de silinmeli, yoksa Firefox artik bos bir dosyaya bakar"
    );
}

#[test]
fn an_absent_key_is_success_not_an_error() {
    // Kullanici kaydi Ayarlar'dan ya da elle sildiyse yeniden denemek hata
    // vermemeli: istenen durum zaten saglanmistir. `NotFound` ayrimi
    // `unregister`'in `delete_subkey_all` hatasindan gelir; test icin ayni
    // hatayi elle uretmek yeterli, kayit defterine dokunmadan.
    let err = std::io::Error::from(std::io::ErrorKind::NotFound);
    let step = UnregisterStep::from_error(&err);
    assert_eq!(step, UnregisterStep::AlreadyAbsent);
    assert_eq!(step.log(), Some("Kayit zaten yok"));
    assert!(step.error().is_none(), "yok sayilmak hata degil");
    assert!(
        !step.removes_manifest(),
        "anahtar yokken davranis degistirilmemis: manifest birakilir (eski sozdelesme)"
    );
}

#[test]
fn any_other_delete_failure_is_reported_with_its_cause() {
    let err = std::io::Error::from(std::io::ErrorKind::PermissionDenied);
    let step = UnregisterStep::from_error(&err);

    let message = step.error().expect("hata donmeli");
    assert!(message.starts_with("Kayit silinemedi: "), "{message}");
    assert!(
        message.len() > "Kayit silinemedi: ".len(),
        "hata nedeni de yazilmali: {message}"
    );
    assert!(!step.removes_manifest(), "hata halinde manifest silinmemeli");
    // Hata adiminin `log()`u `None`: `HATA:` onekini `unregister` kendisi
    // ekler, boylece hata metni tek yerde uretilir.
    assert!(step.log().is_none());

    // Ayni ayrim `NotFound` disindaki her hata icin gecerli.
    for kind in [
        std::io::ErrorKind::PermissionDenied,
        std::io::ErrorKind::InvalidData,
    ] {
        let err = std::io::Error::from(kind);
        assert!(matches!(
            UnregisterStep::from_error(&err),
            UnregisterStep::Failed(_)
        ));
    }
}

/* ---------- gunluk bicimi ---------- */

#[test]
fn log_lines_are_bracketed_timestamps_and_end_with_a_newline() {
    // Gunluk eklenerek yazildigi icin satir sonu zorunlu: son satir kaybolmaz.
    assert_eq!(log_line(0, "Kayit silindi"), "[0] Kayit silindi\n");
    assert_eq!(
        log_line(1_700_000_000, "Kayit yapildi: C:\\a.json"),
        "[1700000000] Kayit yapildi: C:\\a.json\n"
    );

    // Iki satir birlestirildiginde ikincisi yeni satirde baslar.
    let joined = format!("{}{}", log_line(5, "bir"), log_line(6, "iki"));
    assert_eq!(joined, "[5] bir\n[6] iki\n");
    assert_eq!(joined.lines().count(), 2);
}

#[test]
fn register_steps_log_the_messages_the_installed_build_depends_on() {
    // `register.log` tek kullanim yeridir: kurulum sorulunca okunur.
    // Adim adim gunluk metinleri degistirilirse eski kayitlar ve dokumalar
    // tutmaz.
    let value = r"C:\app\com.serene.nmh.json";
    assert_eq!(
        RegisterStep::MissingExecutable(Path::new(r"C:\app\serene-nmh.exe").to_path_buf())
            .log()
            .as_deref(),
        Some("HATA: serene-nmh.exe bulunamadi: C:\\app\\serene-nmh.exe")
    );
    assert_eq!(
        RegisterStep::Registered(value.to_string()).log(),
        Some(format!("Kayit yapildi: {value}"))
    );
    // Gunluk disi adimlar sessiz kalmali: ayni is iki kez yazilmasin.
    assert!(RegisterStep::NeedsRegistryWrite(value.to_string()).log().is_none());
}

/* ---------- kaydin kullanilabilirligi ---------- */

#[test]
fn registration_is_unusable_without_a_value() {
    assert!(!registration_is_usable(None));
}

#[test]
fn registration_is_unusable_when_the_manifest_file_is_gone() {
    // Anahtar var ama manifest silinmis (kurulum sirasinda temizlik olur):
    // Firefox dosyayi acamaz, kayit kullanilamaz sayilir.
    let scratch = Scratch::new("missing-file");
    let gone = scratch.path("com.serene.nmh.json");
    assert!(!gone.exists());
    assert!(!registration_is_usable(Some(&registry_value(&gone))));
}

#[test]
fn registration_is_usable_when_the_value_points_at_an_existing_manifest() {
    let scratch = Scratch::new("usable");
    let dir = scratch.path("nmh");
    let exe = scratch.path(NMH_EXE);
    std::fs::write(&exe, b"sahte ikili").expect("sahte ikili");

    let path = write_manifest_to(&dir, &exe).expect("manifest yazilmali");
    assert!(registration_is_usable(Some(&registry_value(&path))));

    // Deger bos olsa da "kullanilabilir" sayilmaz.
    assert!(!registration_is_usable(Some("")));
}

#[test]
fn the_registry_value_is_the_manifest_path_verbatim() {
    // Bu deger Firefox'un "calistir" adresidir. Tirnaklanirsa Firefox yolu
    // tirnak karakterleriyle arar ve host bulunamaz.
    let path = Path::new(r"C:\Users\ornek\AppData\Roaming\Serene\nmh\com.serene.nmh.json");
    let value = registry_value(path);
    assert_eq!(value, path.to_string_lossy());
    assert!(!value.starts_with('"') && !value.ends_with('"'), "{value}");
    assert!(value.ends_with(".json"), "{value}");
    assert!(Path::new(&value).is_absolute());
}

#[test]
fn the_written_manifest_and_the_registry_value_agree() {
    // Iki uc ayni yolu gostermeli: manifest `path` ikilinin, kayit defteri
    // degeri ise manifestin. Karistirilirsa Firefox kaydi acar ama yanlis
    // dosyayi calistirir.
    let scratch = Scratch::new("agree");
    let dir = scratch.path("nmh");
    let exe = scratch.path(NMH_EXE);
    std::fs::write(&exe, b"sahte ikili").expect("sahte ikili");

    let path = write_manifest_to(&dir, &exe).expect("manifest yazilmali");
    let json = manifest_json(&build_manifest(&exe)).expect("JSON");
    let value: serde_json::Value = serde_json::from_str(&json).expect("JSON");

    assert_eq!(registry_value(&path), path.to_string_lossy());
    assert_eq!(value["path"].as_str(), Some(exe.to_string_lossy().as_ref()));
    assert!(value["path"]
        .as_str()
        .expect("path")
        .ends_with(NMH_EXE));
    assert_eq!(value["allowed_extensions"][0].as_str(), Some(EXTENSION_ID));
    assert_eq!(value["name"].as_str(), Some(HOST_NAME));
}

/* ---------- sadece okuma ---------- */

#[cfg(windows)]
#[test]
fn the_real_registration_can_be_read_without_changing_it() {
    // Makine durumu **okunur**, degistirilmez: ne kayitliysa `reg query` ile
    // ayni sonucu verir. `register`/`unregister` burada cagrilmaz.
    if let Some(value) = serene_native_host::read_registry_value() {
        // Kayitli deger, bizim urettigimiz manifest yolunun bicimiyle olmali.
        assert!(value.ends_with(".json"), "beklenmeyen deger: {value}");
        assert!(
            value.contains(HOST_NAME),
            "deger host adiyla iliskili olmali: {value}"
        );
    }
    // Sonuc ne olursa olsun panik etmemeli: anahtar yoksa `None`.
    let _ = serene_native_host::is_registered();
}
