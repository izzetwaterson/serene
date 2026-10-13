//! Depo butunlugu: yazma sirasinda hicbir an bosluk olmamasi, `.bak`
//! yedegi ve tek bozuk baytin gecmisi silmemesi.
//!
//! Yazma sozlesmesi: (1) gecici dosyaya yaz, (2) `sync_all`, (3) `rename`
//! ile uzerine tasir - birincil dosya hicbir an silinmez. Okuma sozlesmesi:
//! birincil dosya yoksa ya da bozuksa `.bak` yedegi kullanilir; yedek de
//! kullanilamiyorsa varsayilana dusulur.

use std::path::{Path, PathBuf};

use serene_core::models::{CaptureItem, Category, DownloadKind, DownloadMeta, Settings, Status};
use serene_core::store::{
    load_captures, load_settings, load_tasks, save_captures, save_settings, save_tasks,
    take_persist_error, write_json,
};

/// Test basina ayri, surec kimligine gore benzersiz klasor. `Drop` ile
/// silinir; `tempfile` bagimliligi yok.
struct Scratch(PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("serene-store-{}-{tag}", std::process::id()));
        // Onceki kosumdan kalmis olabilecek yarim dosyalar temizlensin.
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("gecici depo klasoru");
        Self(dir)
    }

    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }

    /// Klasorde kalan dosya adlari, sirali.
    fn names(&self) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(&self.0)
            .expect("klasor okunmali")
            .map(|entry| {
                entry
                    .expect("kayit")
                    .file_name()
                    .to_string_lossy()
                    .to_string()
            })
            .collect();
        names.sort();
        names
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn task(id: &str) -> DownloadMeta {
    DownloadMeta {
        id: id.into(),
        url: format!("https://x.dev/{id}.zip"),
        filename: format!("{id}.zip"),
        dest: format!("C:\\tmp\\{id}.zip"),
        temp_dir: format!("C:\\tmp\\.serene\\{id}"),
        total: 100,
        downloaded: 40,
        speed: 0.0,
        status: Status::Paused,
        error: None,
        category: Category::Archive,
        resumable: true,
        segments: Vec::new(),
        created_at: 1,
        finished_at: None,
        etag: None,
        referer: None,
        cookie: None,
        user_agent: None,
        kind: DownloadKind::File,
        source: None,
        pending: false,
    }
}

fn capture(id: &str, url: &str) -> CaptureItem {
    CaptureItem {
        id: id.into(),
        url: url.into(),
        filename: "a.mp4".into(),
        size: 10,
        content_type: "video/mp4".into(),
        kind: DownloadKind::File,
        site: "x.dev".into(),
        created_at: 1,
    }
}

/// `.bak` yolunu dogrudan kurar: testler yedegi birincil gibi yazmamali,
/// yalniz okumali.
fn backup(path: &Path) -> PathBuf {
    let mut name = path.file_name().expect("dosya adi").to_os_string();
    name.push(".bak");
    path.with_file_name(name)
}

fn temp(path: &Path) -> PathBuf {
    let mut name = path.file_name().expect("dosya adi").to_os_string();
    name.push(".tmp");
    path.with_file_name(name)
}

#[test]
fn write_leaves_valid_json_and_no_temp_residue() {
    let scratch = Scratch::new("write");
    let path = scratch.path("tasks.json");

    save_tasks(&path, &[task("a"), task("b")]);

    // Dosya gercekten JSON ve icerigi geri okunabilir.
    let text = std::fs::read_to_string(&path).expect("gorev dosyasi");
    let parsed: Vec<DownloadMeta> = serde_json::from_str(&text).expect("gecerli JSON");
    assert_eq!(parsed.len(), 2);
    assert_eq!(parsed[0].id, "a");

    // Gecici dosya kalmadi: ne birincilin gecicisi ne de yedegin gecicisi
    // (`tasks.json.bak.tmp`).
    assert!(!temp(&path).exists(), "gecici dosya kalmaliydi");
    assert!(
        !scratch.path("tasks.json.bak.tmp").exists(),
        "yedek gecicisi kalmamali"
    );
    assert_eq!(scratch.names(), vec!["tasks.json".to_string()]);

    // Ikinci yazim yedegi de uretir, yine de gecici kalintisi olmaz.
    save_tasks(&path, &[task("c")]);
    assert_eq!(
        scratch.names(),
        vec!["tasks.json".to_string(), "tasks.json.bak".to_string()]
    );
    assert_eq!(load_tasks(&path).len(), 1);
}

#[test]
fn backup_holds_the_previous_write_after_a_crash() {
    let scratch = Scratch::new("crash");
    let path = scratch.path("tasks.json");

    // Ilk yazimda eldeki birincil dosya yok, yedek de olusmaz.
    save_tasks(&path, &[task("ilk")]);
    assert!(!backup(&path).exists(), "ilk yazimda yedek olusmamali");

    // Ikinci yazim yayindan once birincillik durumu yedege tasir.
    save_tasks(&path, &[task("ikinci")]);
    let saved: Vec<DownloadMeta> =
        serde_json::from_str(&std::fs::read_to_string(backup(&path)).expect("yedek dosyasi"))
            .expect("yedek JSON");
    assert_eq!(saved.len(), 1);
    assert_eq!(saved[0].id, "ilk");

    // "Cokme": birincil dosya okunamaz hale gelir. Yedek ilk yazimi tasir,
    // yani hicbir indirme gecmisi kaybolmaz.
    std::fs::write(&path, b"{ ilk yarim kaldi").expect("bozuk icerik");
    let recovered = load_tasks(&path);
    assert_eq!(recovered.len(), 1);
    assert_eq!(recovered[0].id, "ilk");
}

#[test]
fn corrupt_primary_returns_backup_instead_of_empty_list() {
    let scratch = Scratch::new("corrupt");
    let path = scratch.path("tasks.json");

    save_tasks(&path, &[task("ilk")]);
    save_tasks(&path, &[task("ikinci"), task("ucuncu")]);

    // Birincili okunamaz hale getir.
    // Not a JSON: gecerli bir nesne ile eslesmeyen baytlar.
    std::fs::write(&path, b"\x00\x01bozuk baytlar").expect("bozuk icerik");

    let loaded = load_tasks(&path);
    assert_eq!(
        loaded.len(),
        1,
        "bozuk birincil bos listeye dusmemeli, yedek okunmali"
    );
    assert_eq!(loaded[0].id, "ilk");

    // Kurtarma sonrasi yeni bir yazim yine calisir.
    save_tasks(&path, &[task("dorduncu")]);
    assert_eq!(load_tasks(&path).len(), 1);
    assert_eq!(load_tasks(&path)[0].id, "dorduncu");
}

#[test]
fn corrupt_primary_does_not_overwrite_the_good_backup() {
    let scratch = Scratch::new("no-clobber");
    let path = scratch.path("tasks.json");

    save_tasks(&path, &[task("iyi")]);
    save_tasks(&path, &[task("daha yeni")]);
    // Bozuk birincili yedege tasimak iki kopyayi da bozuk birakirdi.
    std::fs::write(&path, b"{{{ bozuk").expect("bozuk icerik");

    save_tasks(&path, &[task("yeni yazim")]);

    let backup: Vec<DownloadMeta> =
        serde_json::from_str(&std::fs::read_to_string(backup(&path)).expect("yedek dosyasi"))
            .expect("yedek JSON");
    assert_eq!(backup.len(), 1);
    assert_eq!(backup[0].id, "iyi", "yedek bozuk icerikle degismemeli");
}

#[test]
fn deleted_primary_returns_backup() {
    let scratch = Scratch::new("deleted");
    let path = scratch.path("tasks.json");

    save_tasks(&path, &[task("ilk")]);
    save_tasks(&path, &[task("ikinci")]);
    std::fs::remove_file(&path).expect("birincil silinmeli");

    let loaded = load_tasks(&path);
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].id, "ilk");
}

#[test]
fn stale_temp_file_is_never_read_as_state() {
    let scratch = Scratch::new("stale-temp");
    let path = scratch.path("tasks.json");

    // Bir onceki cokmeden kalma gecici dosya: ad `tasks.json` degil, bu
    // yuzden gercek durum sanilmamali.
    let payload = serde_json::to_vec(&vec![task("eski")]).expect("JSON");
    std::fs::write(temp(&path), &payload).expect("gecici dosya");
    assert!(
        load_tasks(&path).is_empty(),
        "gecici dosya durum sayilmamali"
    );

    // Ayni adres, dolu olsa bile, sonraki yazimi bozmamali.
    save_tasks(&path, &[task("yeni")]);
    assert!(!temp(&path).exists(), "gecici dosya yazimla temizlenmeli");
    let loaded = load_tasks(&path);
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].id, "yeni");
}

#[test]
fn unusable_state_falls_back_to_default_without_panicking() {
    let scratch = Scratch::new("both-bad");
    let tasks_path = scratch.path("tasks.json");
    let captures_path = scratch.path("captures.json");
    let settings_path = scratch.path("settings.json");

    // Uc durum da elle bozulur: yedek de kullanilamaz.
    for path in [&tasks_path, &captures_path, &settings_path] {
        std::fs::write(path, b"bozuk").expect("bozuk icerik");
        std::fs::write(backup(path), b"daha da bozuk").expect("bozuk yedek");
    }

    assert!(load_tasks(&tasks_path).is_empty());
    assert!(load_captures(&captures_path).is_empty());
    let settings = load_settings(&settings_path);
    assert_eq!(settings.max_concurrent, Settings::default().max_concurrent);
    assert_eq!(settings.download_dir, Settings::default().download_dir);
    assert_eq!(settings.autostart, Settings::default().autostart);

    // hicbir dosya yoksa da ayni sonuc: panik yok, varsayilana donus var.
    assert!(load_tasks(&scratch.path("yok.json")).is_empty());
    assert!(load_captures(&scratch.path("yok.json")).is_empty());
    assert_eq!(
        load_settings(&scratch.path("yok.json")).theme,
        Settings::default().theme
    );
}

#[test]
fn captures_and_settings_share_the_same_backup_rules() {
    let scratch = Scratch::new("others");
    let captures_path = scratch.path("captures.json");
    let settings_path = scratch.path("settings.json");

    let mut first = capture("c1", "https://x.dev/a.mp4");
    save_captures(&captures_path, std::slice::from_ref(&first));
    first.id = "c2".into();
    save_captures(
        &captures_path,
        &[first.clone(), capture("c3", "https://x.dev/b.mp4")],
    );
    std::fs::write(&captures_path, b"[] bozuk").expect("bozuk icerik");
    let captured = load_captures(&captures_path);
    assert_eq!(captured.len(), 1, "bozuk captures.json yedekten okunmali");
    assert_eq!(captured[0].id, "c1");

    let mut settings = Settings {
        autostart: false,
        ..Settings::default()
    };
    save_settings(&settings_path, &settings);
    settings.autostart = true;
    save_settings(&settings_path, &settings);
    std::fs::write(&settings_path, b"nonsense").expect("bozuk icerik");
    let loaded = load_settings(&settings_path);
    assert!(!loaded.autostart, "bozuk settings.json yedekten okunmali");
}

#[test]
fn failed_write_is_recorded_for_the_ui() {
    // Kayit tutulmazsa hata yutulur: kullanici veri kaybini fark etmez.
    // Bu dosyada yalnizca bu test `take_persist_error` okudugu icin
    // surec ici kayit onunla paylasilir.
    assert!(take_persist_error().is_none(), "onceki bir hata kalmamali");

    // Yazma hatasini deterministik uret: hedefin yerinde bir klasor
    // durmasi, `rename`in dosyayi klasorun uzerine tasimasini engeller
    // (Windows'ta `MoveFileExW` klasoru degistiremez, POSIX'ta `EISDIR`).
    let scratch = Scratch::new("fail");
    let path = scratch.path("tasks.json");
    std::fs::create_dir_all(&path).expect("hedef klasor olmali");

    save_tasks(&path, &[task("kaybolmamali")]);

    let error = take_persist_error().expect("yazma hatasi kaydedilmeli");
    assert!(error.contains("tasks.json"), "{error}");
    assert!(
        error.contains("yazilamadi"),
        "hata ne oldugunu soylemeli: {error}"
    );
    // Kayit bir kez tuketilir: arayuz ayni hatayi tekrar tekrar gostermez.
    assert!(take_persist_error().is_none());
}

#[test]
fn load_tasks_still_normalises_restored_statuses() {
    let scratch = Scratch::new("restore");
    let path = scratch.path("tasks.json");

    let mut running = task("kalan");
    running.status = Status::Downloading;
    running.speed = 999.0;
    save_tasks(&path, &[running]);
    save_tasks(&path, &[task("bitti")]);

    std::fs::write(&path, b"bozuk").expect("bozuk icerik");
    let loaded = load_tasks(&path);
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].status, Status::Paused);
    assert_eq!(loaded[0].speed, 0.0);
}

#[test]
fn write_json_publishes_after_syncing_and_keeps_naming_distinct() {
    let scratch = Scratch::new("generic");
    let path = scratch.path("durum.json");

    // Genel yazici da ayni sozlesmeyi uygular (kopru kaydi bunu kullanir).
    let value = serde_json::json!({ "port": 1234 });
    write_json(&path, &value).expect("ilk yazim");
    assert_eq!(read_port(&path), 1234);
    assert!(!temp(&path).exists());
    assert!(!backup(&path).exists(), "ilk yazimda yedek olusmamali");

    write_json(&path, &serde_json::json!({ "port": 5678 })).expect("ikinci yazim");
    assert_eq!(read_port(&path), 5678);
    assert_eq!(read_port(&backup(&path)), 1234);
}

fn read_port(path: &Path) -> i64 {
    let text = std::fs::read_to_string(path).expect("dosya okunmali");
    serde_json::from_str::<serde_json::Value>(&text).expect("JSON")["port"]
        .as_i64()
        .expect("port alani")
}
