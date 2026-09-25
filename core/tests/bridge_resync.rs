//! Koprunun kuyruk tasmasi (`Lagged`) davranisi.
//!
//! Uc sey burada yoklanir:
//!   1. cekirdek kutusu tasirdiginda kopru yarim paketi degil, motorun
//!      gosterdigi tam durumu gonderir ve bunu `resync` turuyle bildirir,
//!   2. istemcinin kendi kuyrugu tasirdiginda da ayni sey olur,
//!   3. `resync` yeni bir turdur: eski istemci onu yok sayar, `reqId`li
//!      istekler (`ping`) yine eslesir.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use serene_core::bridge;
use serene_core::bus::{CoreEvent, EventBus};
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
fn isolated(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("serene-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("gecici veri klasoru");
    std::env::set_var("SERENE_DATA_DIR", &dir);
    dir
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

/// `ipc.json` kaydindan dogrulama token'i.
fn token(bridge: &bridge::Bridge) -> String {
    let text = std::fs::read_to_string(bridge.path()).expect("kopru kaydi");
    serde_json::from_str::<Value>(&text)
        .expect("kayit JSON olmali")
        .pointer("/token")
        .and_then(|token| token.as_str())
        .map(str::to_string)
        .expect("kayitta token olmali")
}

/// Baglanir, el sikistirir, abone olur; `ready`/`subscribed` tuketilir.
fn subscribe(bridge: &bridge::Bridge) -> TcpStream {
    let mut stream = connect(bridge);
    stream
        .write_all(
            format!(
                "{{\"type\":\"hello\",\"token\":\"{}\"}}\n{{\"type\":\"subscribe\"}}\n",
                token(bridge)
            )
            .as_bytes(),
        )
        .expect("hello yazilir");
    stream.flush().expect("yazma yikanir");

    let mut reader = BufReader::new(stream.try_clone().expect("kopyalanan soket"));
    let deadline = Instant::now() + Duration::from_secs(10);
    let (mut ready, mut subscribed) = (false, false);
    while !(ready && subscribed) {
        let Some(value) = read_line(&mut reader, deadline) else {
            break;
        };
        match kind_of(&value) {
            "ready" => ready = true,
            "subscribed" => subscribed = true,
            _ => {}
        }
    }
    assert!(ready, "ready yaniti gelmeli");
    assert!(subscribed, "subscribed yaniti gelmeli");
    stream
}

/// Kopruye baglanir ve okuma suresini sinirlar; `read_line` bu olmadan
/// bloklanip testi asili tutabilir.
fn connect(bridge: &bridge::Bridge) -> TcpStream {
    let stream = TcpStream::connect(("127.0.0.1", bridge.port())).expect("kopruye baglan");
    stream
        .set_read_timeout(Some(Duration::from_millis(200)))
        .expect("okuma suresi ayarlanir");
    stream
}

/// Soketten sirayla satir okur; `deadline` gecerse `None` doner.
///
/// Sokette 200 ms'lik okuma suresi vardir: `deadline`i beklerken `read_line`
/// tekrar tekrar bloklanmaz.
fn read_line(reader: &mut BufReader<TcpStream>, deadline: Instant) -> Option<Value> {
    let mut line = String::new();
    loop {
        if Instant::now() >= deadline {
            return None;
        }
        line.clear();
        match reader.read_line(&mut line) {
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

fn kind_of(value: &Value) -> &str {
    value
        .get("type")
        .and_then(|kind| kind.as_str())
        .unwrap_or("")
}

fn payload_of(value: &Value) -> Vec<Value> {
    value
        .get("payload")
        .and_then(|payload| payload.as_array())
        .cloned()
        .unwrap_or_default()
}

/// Bildirimden sonra motorun tam durumu geldi mi? Gelen mesajlar motorun
/// listesini yansittigi icin eski bir `tasks` satiri yeterli degildir.
fn converged(seen: &[Value]) -> bool {
    let Some(start) = seen
        .iter()
        .position(|value| kind_of(value) == bridge::RESYNC_TYPE)
    else {
        return false;
    };
    let after = &seen[start..];
    let tasks = after.iter().any(|value| {
        kind_of(value) == "tasks"
            && payload_of(value)
                .iter()
                .any(|meta| meta.get("id").and_then(|id| id.as_str()) == Some("kayip"))
    });
    let captures = after
        .iter()
        .any(|value| kind_of(value) == "captures" && payload_of(value).len() == 1);
    tasks && captures
}

/// Okumaya baslar ve kopru toparlanana kadar satirlari toplar.
fn collect_until_converged(reader: &mut BufReader<TcpStream>, seconds: u64) -> Vec<Value> {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let mut seen: Vec<Value> = Vec::new();
    while Instant::now() < deadline {
        let Some(value) = read_line(reader, deadline) else {
            continue;
        };
        seen.push(value);
        if converged(&seen) {
            break;
        }
    }
    seen
}

/// Cekirdek kutusu tasmasi: istemci yarim paketi degil, motorun gosterdigi
/// tam durumu alir.
///
/// Istemci once okumaz; yuz binlerce olay yayinlandiginda hem cekirdek kutusu
/// hem de istemci kanali tasar. Okuma basladiktan sonra `resync` bildirimi
/// ve onu izleyen tam `tasks`/`captures` satirlari gorunmelidir.
#[test]
fn lagged_subscriber_gets_authoritative_state_not_a_partial_batch() {
    let _serial = lock_dir();
    let dir = isolated("bridge-resync");
    let bus = EventBus::default();
    let manager = DownloadManager::new(bus.clone()).expect("motor");
    manager.insert(task("kayip", &dir));
    manager.add_capture(capture());

    let bridge =
        runtime::block_on(bridge::start(bus.clone(), Arc::clone(&manager))).expect("kopru");
    let stream = subscribe(&bridge);
    let mut reader = BufReader::new(stream.try_clone().expect("kopyalanan soket"));

    // Okumadan birikim: yayin hizindan belirgin sekilde uzun.
    for _ in 0..30_000 {
        bus.publish(CoreEvent::Progress(vec![]));
    }
    for _ in 0..30_000 {
        bus.publish(CoreEvent::Tasks(vec![]));
    }

    let seen = collect_until_converged(&mut reader, 20);
    let start = seen
        .iter()
        .position(|value| kind_of(value) == bridge::RESYNC_TYPE)
        .unwrap_or_else(|| {
            panic!(
                "kopru kaybi `resync` ile bildirmeli; gorulen turler: {:?}",
                seen.iter().map(kind_of).collect::<Vec<_>>()
            )
        });

    // Bildirim kac olayin dustugunu soyler ve sifir olmaz.
    let missed = seen[start]
        .pointer("/payload/missed")
        .and_then(|value| value.as_u64())
        .expect("missed sayimi");
    assert!(missed > 0, "bildirim kac olayin dustugunu soylemeli");

    // Bildirimden sonra motorun tam durumu gelir; yarim paket gonderilmez.
    assert!(
        converged(&seen[start..]),
        "bildirimi tam gorev ve yakalama listesi izlemeli"
    );

    drop(stream);
    bridge::cleanup(bridge.path());
    drop(manager);
    let _ = std::env::remove_var("SERENE_DATA_DIR");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Geriye donuk uyumluluk: yeni turun adini bilmeyen istemci `ping` istegini
/// yine alir; koprunun `reqId` yankisi degismez.
#[test]
fn resync_notice_does_not_break_reqid_matching() {
    let _serial = lock_dir();
    let dir = isolated("bridge-reqid");
    let bus = EventBus::default();
    let manager = DownloadManager::new(bus.clone()).expect("motor");
    let bridge = runtime::block_on(bridge::start(bus, Arc::clone(&manager))).expect("kopru");

    let mut stream = connect(&bridge);
    let req_id = "r-test-1";
    stream
        .write_all(
            format!(
                "{{\"type\":\"hello\",\"token\":\"{}\"}}\n{{\"type\":\"ping\",\"reqId\":\"{req_id}\"}}\n",
                token(&bridge)
            )
            .as_bytes(),
        )
        .expect("istek yazilir");
    stream.flush().expect("yazma yikanir");

    let mut reader = BufReader::new(stream.try_clone().expect("kopyalanan soket"));
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut pong = false;
    while let Some(value) = read_line(&mut reader, deadline) {
        if value.get("reqId").and_then(|id| id.as_str()) != Some(req_id) {
            // `ready` ve yeni turler yoksayilir; eski istemci de boyle yapar.
            continue;
        }
        assert_eq!(kind_of(&value), "pong", "eslesen yanit pong olmali");
        pong = true;
        break;
    }
    assert!(pong, "ping yaniti gelmeli");

    drop(stream);
    bridge::cleanup(bridge.path());
    drop(manager);
    let _ = std::env::remove_var("SERENE_DATA_DIR");
    let _ = std::fs::remove_dir_all(&dir);
}
