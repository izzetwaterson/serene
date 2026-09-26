//! Koprunun `subscribe` cevabi ve duzgun kapanmada kayit temizligi.
//!
//! Uc sey burada yoklanir:
//!   1. yeni abone, hicbir komut gondermeden motorun gosterdigi tam gorev
//!      listesini ve yakalananlari alir (uygulama bos bir liste sanmaz),
//!   2. bu itme geriye donuk uyumludur: turlerden birini bilmeyen eski
//!      istemci baglantiyi kullanmaya devam eder, `reqId` eslesmesi degismez,
//!   3. duzgun kapanma `ipc.json` ile birlikte `ipc.json.bak` yedegini de
//!      siler, ayni klasordeki diger durum dosyalarina dokunmaz.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use serene_core::bridge;
use serene_core::bridge::Bridge;
use serene_core::bus::EventBus;
use serene_core::manager::DownloadManager;
use serene_core::models::{CaptureItem, DownloadMeta};
use serene_core::runtime;

/// `SERENE_DATA_DIR` surec genelidir ve motor her okumada degiskene bakar.
/// Bu yuzden motor kuran testler arasi sirali calisir; aksi halde iki kopru
/// birbirinin kaydini ve klasorunu bozardi.
static DATA_DIR: Mutex<()> = Mutex::new(());

fn lock_dir() -> MutexGuard<'static, ()> {
    DATA_DIR
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Testin izole veri klasoru; kosumlar gibi `SERENE_DATA_DIR` ile.
fn isolated(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("serene-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("gecici veri klasoru");
    std::env::set_var("SERENE_DATA_DIR", &dir);
    dir
}

/// Testin izole klasorunu kaldirir. `SERENE_DATA_DIR` surec geneli oldugu
/// icin geride birakilirsa sonraki motor okumasi yanlis klasoru gorur.
fn teardown(dir: PathBuf) {
    std::env::remove_var("SERENE_DATA_DIR");
    let _ = std::fs::remove_dir_all(dir);
}

/// Yonetilen bir dosya yolu: `ipc.json` -> `ipc.json.bak`.
fn backup_of(path: &Path) -> PathBuf {
    let mut name = path.file_name().expect("dosya adi").to_os_string();
    name.push(".bak");
    path.with_file_name(name)
}

fn task(id: &str, dir: &Path) -> DownloadMeta {
    let slash = |value: String| value.replace('\\', "\\\\");
    serde_json::from_str(&format!(
        r#"{{
            "id": "{id}",
            "url": "https://ornek.test/{id}.bin",
            "filename": "{id}.bin",
            "dest": "{dest}",
            "temp_dir": "{temp}",
            "total": 2048,
            "downloaded": 1024,
            "speed": 0.0,
            "status": "paused",
            "error": null,
            "category": "other",
            "resumable": true,
            "segments": [],
            "created_at": 1,
            "finished_at": null
        }}"#,
        dest = slash(dir.join(format!("{id}.bin")).to_string_lossy().into_owned()),
        temp = slash(
            dir.join(format!(".serene-{id}"))
                .to_string_lossy()
                .into_owned()
        ),
    ))
    .expect("gorev okunmali")
}

fn capture() -> CaptureItem {
    serde_json::from_value(json!({
        "id": "y1",
        "url": "https://ornek.test/a.mp4",
        "filename": "a.mp4",
        "size": 10,
        "contentType": "video/mp4",
        "kind": "file",
        "site": "ornek.test",
        "createdAt": 1,
    }))
    .expect("yakalama okunmali")
}

/// Baglanmis ve el sikismis istemci. Satirlari tek tek toplar; soketin okuma
/// suresi kisa oldugu icin `deadline` dolunca beklemez.
struct Client {
    reader: BufReader<TcpStream>,
    writer: TcpStream,
}

impl Client {
    /// Kopruye baglanir; `ipc.json` kaydindan dogrulama token'ini okur.
    fn connect(bridge: &Bridge) -> Self {
        let stream = TcpStream::connect(("127.0.0.1", bridge.port())).expect("kopruye baglan");
        // `read_line` bu olmadan bloklanip testi asili tutabilir.
        stream
            .set_read_timeout(Some(Duration::from_millis(200)))
            .expect("okuma suresi ayarlanir");
        let token = std::fs::read_to_string(bridge.path()).expect("kopru kaydi");
        let token: Value = serde_json::from_str(&token).expect("kayit JSON olmali");
        let token = token
            .pointer("/token")
            .and_then(|token| token.as_str())
            .expect("kayitta token olmali")
            .to_string();
        let mut client = Self {
            reader: BufReader::new(stream.try_clone().expect("kopyalanan soket")),
            writer: stream,
        };
        client.send(&format!(r#"{{"type":"hello","token":"{token}"}}"#));
        client
    }

    fn send(&mut self, line: &str) {
        writeln!(self.writer, "{line}").expect("istek yazilir");
        self.writer.flush().expect("yazma yikanir");
    }

    /// `hello` gonderildi; `ready` gorulene kadar bekler.
    fn handshake(&mut self) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            let Some(value) = self.read(deadline) else {
                continue;
            };
            if kind_of(&value) == "ready" {
                return;
            }
        }
        panic!("ready yaniti gelmeli");
    }

    /// Verilen sure icinde gelen tum satirlari dondurur.
    fn drain(&mut self, seconds: u64) -> Vec<Value> {
        let deadline = Instant::now() + Duration::from_secs(seconds);
        let mut seen = Vec::new();
        while Instant::now() < deadline {
            let Some(value) = self.read(deadline) else {
                continue;
            };
            seen.push(value);
        }
        seen
    }

    /// Soketten sirayla satir okur; `deadline` gecerse `None` doner.
    fn read(&mut self, deadline: Instant) -> Option<Value> {
        let mut line = String::new();
        loop {
            if Instant::now() >= deadline {
                return None;
            }
            line.clear();
            match self.reader.read_line(&mut line) {
                Ok(0) => return None,
                Ok(_) => {}
                // Zaman asimi: yeniden dene, yalnizca `deadline` karar verir.
                Err(_) => continue,
            }
            let trimmed = line.trim().to_string();
            if trimmed.is_empty() {
                continue;
            }
            if let Ok(value) = serde_json::from_str::<Value>(&trimmed) {
                return Some(value);
            }
        }
    }
}

fn kind_of(value: &Value) -> &str {
    value
        .get("type")
        .and_then(|kind| kind.as_str())
        .unwrap_or("")
}

/// Mesajin `reqId` alani; istek yaniti degilse `None`.
fn req_id_of(value: &Value) -> Option<&str> {
    value.get("reqId").and_then(|id| id.as_str())
}

fn payload_of(value: &Value) -> &Value {
    value.get("payload").unwrap_or(&Value::Null)
}

fn ids_of(value: &Value) -> Vec<String> {
    payload_of(value)
        .as_array()
        .map(|list| {
            list.iter()
                .map(|item| {
                    item.get("id")
                        .and_then(|id| id.as_str())
                        .unwrap_or("")
                        .to_string()
                })
                .collect()
        })
        .unwrap_or_default()
}

/// `tasks`/`captures` satirini arar; abonenin ilk tam durumu budur.
fn find<'a>(seen: &'a [Value], kind: &str) -> &'a Value {
    seen.iter()
        .find(|value| kind_of(value) == kind)
        .unwrap_or_else(|| {
            panic!(
                "`{kind}` satiri gelmeli; gorulen turler: {:?}",
                seen.iter().map(kind_of).collect::<Vec<_>>()
            )
        })
}

/// Yeni abone motorun gosterdigi tam durumu kendi istegiyle alir: ne `list`
/// ne de bir degisiklik gerekir, uygulama bos bir liste sanmaz.
#[test]
fn subscribing_client_gets_tasks_and_captures_without_any_other_command() {
    let _serial = lock_dir();
    let dir = isolated("bridge-subscribe");
    let bus = EventBus::default();
    let manager = DownloadManager::new(bus.clone()).expect("motor");
    // Motor calismiyor; hicbir indirme yok, bekleyen iki gorev var.
    manager.insert(task("bekleyen", &dir));
    manager.insert(task("duraklatilmis", &dir));
    manager.add_capture(capture());

    let bridge = runtime::block_on(bridge::start(bus, Arc::clone(&manager))).expect("kopru");
    let mut client = Client::connect(&bridge);
    client.handshake();
    client.send(r#"{"type":"subscribe"}"#);

    // Tek istek `subscribe`; `ready` el sikismada tuketildi, okunan her sey
    // bu abonenin cevabi: once onay, hemen ardindan tam durum.
    let seen = client.drain(1);
    let kinds: Vec<&str> = seen.iter().map(kind_of).collect();
    assert_eq!(
        kinds,
        ["subscribed", "tasks", "captures"],
        "abonelik tam durumu onaydan hemen sonra vermeli"
    );

    // Gorev listesi geldi ve istemci onu cozebiliyor.
    let tasks = find(&seen, "tasks");
    let parsed: Vec<DownloadMeta> =
        serde_json::from_value(payload_of(tasks).clone()).expect("gorev listesi cozulmeli");
    let mut ids: Vec<&str> = parsed.iter().map(|meta| meta.id.as_str()).collect();
    ids.sort_unstable();
    assert_eq!(
        ids,
        ["bekleyen", "duraklatilmis"],
        "her iki gorev de itilmeli"
    );

    // Yakalananlar da ayni cevapta gelir.
    let captures = find(&seen, "captures");
    let parsed: Vec<CaptureItem> =
        serde_json::from_value(payload_of(captures).clone()).expect("yakalama listesi cozulmeli");
    assert_eq!(parsed.len(), 1);
    assert_eq!(parsed[0].id, "y1");

    // Durum yaklasmis: itilen liste `list` isteginin dondurdugu ile ayni.
    client.send(r#"{"type":"list","reqId":"r-liste-1"}"#);
    let listed = client.drain(1);
    let answer = listed
        .iter()
        .find(|value| req_id_of(value) == Some("r-liste-1"))
        .expect("liste yaniti gelmeli");
    assert_eq!(kind_of(answer), "tasks");
    assert_eq!(
        payload_of(answer),
        payload_of(tasks),
        "abonenin durumu `list` ile ayni olmali"
    );
    assert_eq!(ids_of(tasks).len(), 2, "itilen liste iki gorev icermeli");

    bridge::cleanup(bridge.path());
    drop(manager);
    teardown(dir);
}

/// Ikinci `subscribe` yeni kanal kurmaz ama tam durumu yine de gonderir:
/// her abonelik ayni sonucu vermeli, istemci durumunu sifirlamak zorunda
/// kalmamali.
#[test]
fn subscribing_twice_pushes_the_state_again() {
    let _serial = lock_dir();
    let dir = isolated("bridge-subscribe-twice");
    let bus = EventBus::default();
    let manager = DownloadManager::new(bus.clone()).expect("motor");
    manager.insert(task("tek-gorev", &dir));

    let bridge = runtime::block_on(bridge::start(bus, Arc::clone(&manager))).expect("kopru");
    let mut client = Client::connect(&bridge);
    client.handshake();
    client.send(r#"{"type":"subscribe"}"#);
    let first = client.drain(1);
    assert_eq!(ids_of(find(&first, "tasks")), ["tek-gorev"]);

    client.send(r#"{"type":"subscribe","reqId":"r-tekrar-1"}"#);
    let second = client.drain(1);
    let kinds: Vec<&str> = second.iter().map(kind_of).collect();
    assert_eq!(
        kinds,
        ["subscribed", "tasks", "captures"],
        "her abonelik once onay, sonra tam durum vermeli"
    );
    assert_eq!(
        second
            .iter()
            .find(|value| req_id_of(value) == Some("r-tekrar-1"))
            .map(kind_of),
        Some("subscribed"),
        "onay istegin reqId'sini yine yansitmali"
    );
    assert_eq!(ids_of(find(&second, "tasks")), ["tek-gorev"]);

    bridge::cleanup(bridge.path());
    drop(manager);
    teardown(dir);
}

/// Geriye donuk uyumluluk: `subscribe` cevabinda tur eklenmez. Bildigi
/// sekiz turu isleyen eski bir istemci (digerini yok sayan) hem durumu alir
/// hem de baglantiyi kullanmaya devam eder; `reqId` yankisi degismez.
#[test]
fn a_client_that_ignores_unknown_types_keeps_working() {
    let _serial = lock_dir();
    let dir = isolated("bridge-subscribe-legacy");
    let bus = EventBus::default();
    let manager = DownloadManager::new(bus.clone()).expect("motor");
    manager.insert(task("eski-gorev", &dir));

    let bridge = runtime::block_on(bridge::start(bus, Arc::clone(&manager))).expect("kopru");
    let mut client = Client::connect(&bridge);
    client.handshake();
    client.send(r#"{"type":"subscribe"}"#);
    let seen = client.drain(1);

    // Eski istemcinin tanidigi turler; baska bir tur gelirse yok sayilir.
    const KNOWN: [&str; 9] = [
        "ready",
        "subscribed",
        "tasks",
        "captures",
        "progress",
        "ack",
        "ok",
        "pong",
        "error",
    ];
    for value in &seen {
        let kind = kind_of(value);
        assert!(
            KNOWN.contains(&kind),
            "baglantiyi bozan yeni tur gelmemeli: {kind}"
        );
        assert_ne!(kind, "error", "abonelik hataya donusmemeli");
    }
    // Durum yine de elde: yeni istemcinin ekleyecegi bir tur olsaydi eski
    // istemci bunu yok sayip bu listeyi kullanirdi.
    assert_eq!(ids_of(find(&seen, "tasks")), ["eski-gorev"]);

    // Baglanti ayakta ve istek/yanit eslesmesi bozulmamis.
    let req_id = "r-legacy-1";
    client.send(&format!(r#"{{"type":"ping","reqId":"{req_id}"}}"#));
    let pong = client
        .drain(1)
        .into_iter()
        .find(|value| req_id_of(value) == Some(req_id))
        .expect("ping yaniti gelmeli");
    assert_eq!(kind_of(&pong), "pong");
    assert!(pong.pointer("/payload/version").is_some());

    bridge::cleanup(bridge.path());
    drop(manager);
    teardown(dir);
}

/// Duzgun kapanma kopru kaydini ve `.bak` yedesini birlikte siler; ayni
/// klasordeki diger durum dosyalari (ve onlarin yedekleri) yerinde kalir.
#[test]
fn clean_shutdown_removes_the_bridge_record_and_its_backup() {
    let _serial = lock_dir();
    let dir = isolated("bridge-cleanup");
    let bus = EventBus::default();
    let manager = DownloadManager::new(bus.clone()).expect("motor");

    // Ikinci acilista `store::write_json` birincil kaydi `.bak` olarak
    // yedekler; yani yedek ancak gercek bir kapanmadan sonra kalir.
    let first = runtime::block_on(bridge::start(bus.clone(), Arc::clone(&manager))).expect("kopru");
    let second = runtime::block_on(bridge::start(bus, Arc::clone(&manager))).expect("kopru");
    let record = second.path().to_path_buf();
    assert_eq!(first.path(), record, "kayit yeri degismemeli");
    assert!(record.exists(), "kopru kaydi yazilmali");
    let backup = backup_of(&record);
    assert!(backup.exists(), "onceki kaydin yedegi yazilmali");

    // Ayni klasordeki baska durum dosyalari: yedekli yazma yolunun ortagi.
    let tasks = dir.join("tasks.json");
    let tasks_backup = backup_of(&tasks);
    std::fs::write(&tasks, "[]").expect("gorev dosyasi yazilir");
    std::fs::write(&tasks_backup, "[]").expect("gorev yedegi yazilir");

    bridge::cleanup(&record);

    assert!(!record.exists(), "kopru kaydi silinmeli");
    assert!(!backup.exists(), "kopru yedegi de silinmeli");
    assert!(tasks.exists(), "ilgisiz durum dosyasi yerinde kalmali");
    assert!(tasks_backup.exists(), "ilgisiz yedek yerinde kalmali");

    // Kapanma ikinci kez cagrilsa da cokmeden gecmeli.
    bridge::cleanup(&record);

    drop(manager);
    teardown(dir);
}
