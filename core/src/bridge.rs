//! Yerel kopru: ayni makinedeki sureclerin (Firefox native messaging host'u)
//! Serene'ye indirme eklemesini ve olay akisina abone olmasini saglar.
//!
//! Guvenlik: yalnizca 127.0.0.1 uzerinde dinlenir ve ilk mesajda
//! `%APPDATA%\Serene\ipc.json` icindeki rastgele token dogrulanir. Boylece
//! tarayicida calisan bir web sayfasi kopruye erisemez.
//!
//! Tel bicimi: satir sonu ayrilmis JSON. Uygulamadan giden her mesaj
//! `{ type, reqId?, payload }` seklindedir.
//!
//! `subscribe` cevabi: once `subscribed` (istegin `reqId` yankisi), hemen
//! ardindan motorun gosterdigi tam durum - `tasks` ve `captures`. Yeni tur
//! eklenmez; eski istemci zaten bildigi `tasks`/`captures` satirlarini
//! alir, `reqId` ile eslestirmeyen istemci ise bu satirlari yok sayar.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{broadcast, mpsc};
use tokio::time::Instant;

use crate::bus::{CoreEvent, EventBus};
use crate::engine;
use crate::enqueue;
use crate::manager::DownloadManager;
use crate::models::{now_secs, CaptureItem, DownloadKind, DownloadMeta};
use crate::runtime;
use crate::store;

pub const IPC_FILE: &str = "ipc.json";

/// Tel biciminde gonderilen olayin turu: abonenin geride kaldigini bildirir.
/// Eski istemci bilinmeyen turu yok sayar ve koprunun hemen ardindan
/// gonderdigi tam durumla yine de yaklasir; yani ekleme geriye donuk
/// uyumludur.
pub const RESYNC_TYPE: &str = "resync";

/// Koprunun kendi yayin kanalindaki kapasite. Gonderme bloklamaz, doldugu
/// icin en eski mesaj dusmeye baslar; kapasite buyutuldukce yavas istemci
/// daha gek yakalar. Asil duzeltme yine de `Lagged` yakalandiginda durumun
/// yeniden okunmasidir.
const CLIENT_QUEUE: usize = 512;

/// Ayni istemciye arka arkaya toparlama bildiriminin gonderilme araligi.
/// Tasma bir kez olustu mu durum zaten tam gonderilmistir; saniyede bir
/// bildirim yeter, aradaki tasmalar bir sonraki tam listeyle ya da istemcinin
/// `list` istegiyle kapanir.
const RESYNC_MIN_GAP: Duration = Duration::from_millis(500);

/// Kopruye baglanmak icin gereken bilgiler; diske yazilir.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct IpcInfo {
    pub port: u16,
    pub token: String,
    pub pid: u32,
    pub version: String,
}

pub struct Bridge {
    info: IpcInfo,
    path: PathBuf,
    events: broadcast::Sender<String>,
    clients: Arc<AtomicUsize>,
}

impl Bridge {
    pub fn port(&self) -> u16 {
        self.info.port
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Su an el sikismasini tamamlamis baglanti sayisi.
    pub fn clients(&self) -> usize {
        self.clients.load(Ordering::Relaxed)
    }

    pub fn status(&self) -> BridgeStatus {
        BridgeStatus {
            port: self.info.port,
            version: self.info.version.clone(),
            clients: self.clients(),
        }
    }
}

/// Arayuze donen kopru ozeti; token disari verilmez.
#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BridgeStatus {
    pub port: u16,
    pub version: String,
    pub clients: usize,
}

/// Baglanti sayaci; baglanti nasil biterse bitsin sayaci dusurur.
struct ClientGuard(Arc<AtomicUsize>);

impl ClientGuard {
    fn enter(counter: &Arc<AtomicUsize>) -> Self {
        counter.fetch_add(1, Ordering::Relaxed);
        Self(Arc::clone(counter))
    }
}

impl Drop for ClientGuard {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
}

/// Gelen mesaj. Bilinmeyen alanlar yok sayilir; boylece eklenti tarafi
/// protokole alan eklediginde eski surum bozulmaz.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Incoming {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    token: Option<String>,
    #[serde(default)]
    req_id: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    dest_dir: Option<String>,
    /// Istek basliklari ve gorev turu; eklenti gondermezse varsayilan kalir.
    #[serde(default)]
    referer: Option<String>,
    #[serde(default)]
    cookie: Option<String>,
    #[serde(default)]
    user_agent: Option<String>,
    #[serde(rename = "kind", default)]
    download_kind: Option<DownloadKind>,
    #[serde(default)]
    source: Option<String>,
    /// `capture` mesajinin alanlari; `enqueue` gibi duz, `payload` altinda degil.
    /// `kind` yukaridaki `download_kind` ile ayni alandir (medya turu).
    #[serde(default)]
    filename: Option<String>,
    #[serde(default)]
    size: Option<u64>,
    #[serde(default)]
    content_type: Option<String>,
    #[serde(default)]
    site: Option<String>,
    /// Yakalanan oge kimligi (`download_capture`).
    #[serde(default)]
    id: Option<String>,
}

fn new_token() -> String {
    format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    )
}

fn error_message(req_id: Option<String>, message: &str) -> String {
    serde_json::json!({
        "type": "error",
        "reqId": req_id,
        "payload": { "message": message },
    })
    .to_string()
}

/// Kopru tel biciminde tek bir olay satiri: `{ type, payload }`.
fn event_line(kind: &str, payload: serde_json::Value) -> String {
    serde_json::json!({ "type": kind, "payload": payload }).to_string()
}

/// Abonenin geride kaldigini bildiren satir. `missed` kac olayin dusdugunu
/// soyler; eski istemci bu turu bilmez ve yok sayar.
fn resync_line(missed: u64) -> String {
    event_line(RESYNC_TYPE, serde_json::json!({ "missed": missed }))
}

/// Motorun gosterdigi son durum: gorevler ve yakalananlar.
///
/// Motor tek dogrudur; bu iki satir her yerde (kuyruk tasmasi, yeni abone)
/// liste yerine gecer, boylece abone tahmin yapmaz.
fn state_lines(manager: &DownloadManager) -> Vec<String> {
    vec![
        event_line("tasks", serde_json::json!(manager.snapshot())),
        event_line("captures", serde_json::json!(manager.captures())),
    ]
}

/// Cekirdek olayini kopru tel bicimine cevirip abonelere dagitir.
/// Koprunun umursamadigi olaylar (onay penceresi, pano) atlanir.
fn forward(events: &broadcast::Sender<String>, event: &CoreEvent) {
    let (kind, payload) = match event {
        CoreEvent::Tasks(tasks) => ("tasks", serde_json::json!(tasks)),
        CoreEvent::Progress(ticks) => ("progress", serde_json::json!(ticks)),
        CoreEvent::Captures(items) => ("captures", serde_json::json!(items)),
        CoreEvent::HandoffPending(_) | CoreEvent::ClipboardLink(_) => return,
        CoreEvent::PresentWindow => return,
        // Depolama hatasi tarayiciya degil, masaustu kullanicisina aittir;
        // eklenti bunu gormemeli, hatta bildirim olarak gostermemeli.
        CoreEvent::StorageError(_) => return,
    };
    let _ = events.send(event_line(kind, payload));
}

/// Cekirdek kutusu tasirmis: gonderilemeyen olaylarin yerine motorun gosterdigi
/// son durum konur. Gonderme bloklamadigi icin yavas istemci bu yoldan da
/// engellenmez; acik bildirim once, tam durum hemen ardindan gider, boylece
/// abone neyin dustugunu bilir ve listeden sonra yarisini gormez.
fn replay(events: &broadcast::Sender<String>, manager: &DownloadManager, missed: u64) {
    let _ = events.send(resync_line(missed));
    for line in state_lines(manager) {
        let _ = events.send(line);
    }
}

/// Kopruyu baslatir, `ipc.json`'u yazar ve kabul dongusunu arka planda kurar.
pub async fn start(bus: EventBus, manager: Arc<DownloadManager>) -> anyhow::Result<Arc<Bridge>> {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
    let port = listener.local_addr()?.port();

    let info = IpcInfo {
        port,
        token: new_token(),
        pid: std::process::id(),
        version: env!("CARGO_PKG_VERSION").to_string(),
    };

    // Onceki oturumdan kalan dosya varsa uzerine yazilir; bayat dosya
    // istemci tarafinda yalnizca "baglanti reddedildi" sonucunu dogurur.
    let path = store::data_dir().join(IPC_FILE);
    store::write_json(&path, &info)?;

    let (events, _) = broadcast::channel::<String>(CLIENT_QUEUE);
    let bridge = Arc::new(Bridge {
        info,
        path,
        events: events.clone(),
        clients: Arc::new(AtomicUsize::new(0)),
    });

    {
        let events = events.clone();
        let mut rx = bus.subscribe();
        let manager = Arc::clone(&manager);
        runtime::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(event) => forward(&events, &event),
                    // Kuyruk tasirdi: yarim olay paketi iletilmez, sadece
                    // sonraki olayla devam edilmez. Motor tek dogrudur; bu
                    // yuzden durum yeniden okunur ve tum abonelere tam liste
                    // olarak geri verilir. Ilerleme zaten anlik sayilardir ve
                    // tam listedeki `downloaded` ile duzelir.
                    Err(broadcast::error::RecvError::Lagged(missed)) => {
                        replay(&events, &manager, missed);
                    }
                    Err(_) => break,
                }
            }
        });
    }

    let accept_bridge = Arc::clone(&bridge);
    let accept_bus = bus.clone();
    runtime::spawn(async move {
        loop {
            let Ok((stream, _addr)) = listener.accept().await else {
                continue;
            };
            let bridge = Arc::clone(&accept_bridge);
            let bus = accept_bus.clone();
            let manager = Arc::clone(&manager);
            runtime::spawn(async move {
                let _ = serve(bridge, bus, manager, stream).await;
            });
        }
    });

    Ok(bridge)
}

/// Kopru dosyasini siler; uygulama duzgun kapanirken cagrilir.
///
/// `store::write_json` her yazma icin bir `.bak` kardesini birakir (bozuk bir
/// birincil dosyadan kurtulmanin yolu bu), yalnizca birincili silmek duzgun
/// kapanmadan sonra bayat bir yedegi sonsuza kadar birakirdi. Ikisi de bu
/// dosyadan turetilir; data klasorundeki baska hicbir dosyaya dokunulmaz.
pub fn cleanup(path: &Path) {
    let _ = std::fs::remove_file(path);
    if let Some(name) = path.file_name() {
        let mut backup = name.to_os_string();
        backup.push(".bak");
        let _ = std::fs::remove_file(path.with_file_name(backup));
    }
}

/// `ipc.json`'daki kopruye tek bir istek yollar ve eslesen yaniti donerir.
/// Kabugun kendi motorunu kurmadan calisan ornege seslenmesi icin: tek ornek
/// korumasinda `show`, onay penceresinde `set_dest` ve `resume`.
///
/// Bloklayicidir; iki saniyede yanit gelmezse hata doner. Kayit yoksa, port
/// oluksa ya da token tutmuyorsa da hata — yani "baska ornek yok".
pub fn request(op: &str, args: &serde_json::Value) -> Result<serde_json::Value, String> {
    use std::io::{BufRead, Write};

    let info = read_ipc().ok_or("Calisan bir Serene ornegi bulunamadi")?;
    let stream = std::net::TcpStream::connect(("127.0.0.1", info.port))
        .map_err(|_| "Calisan ornege baglanilamadi".to_string())?;
    let timeout = Some(std::time::Duration::from_secs(2));
    let _ = stream.set_read_timeout(timeout);
    let _ = stream.set_write_timeout(timeout);

    let req_id = uuid::Uuid::new_v4().simple().to_string();
    let mut request = serde_json::json!({ "type": op, "reqId": req_id });
    if let (Some(fields), Some(object)) = (args.as_object(), request.as_object_mut()) {
        object.extend(fields.clone());
    }
    let hello = serde_json::json!({ "type": "hello", "token": info.token });

    let mut writer = &stream;
    writeln!(writer, "{hello}")
        .and_then(|_| writeln!(writer, "{request}"))
        .map_err(|_| "Istek gonderilemedi".to_string())?;

    // Abonelikli baglantilarda kendi yanitimizdan once bildim gelebilir;
    // yalnizca `reqId` eslesen satir sonucu tasir.
    let mut reader = std::io::BufReader::new(&stream);
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => return Err("Ornek yanit vermeden baglantiyi kapatti".into()),
            Ok(_) => {}
            Err(_) => return Err("Ornekten yanit alinamadi".into()),
        }
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        if value.get("reqId").and_then(|id| id.as_str()) != Some(req_id.as_str()) {
            continue;
        }
        return match value.get("type").and_then(|kind| kind.as_str()) {
            Some("error") => Err(value
                .pointer("/payload/message")
                .and_then(|message| message.as_str())
                .unwrap_or("Ornek istegi reddetti")
                .to_string()),
            Some("ok" | "ack" | "pong" | "tasks") => {
                Ok(value.get("payload").cloned().unwrap_or_default())
            }
            _ => continue,
        };
    }
}

/// Calisan ornegin kopru kaydi; yoksa ya da bozuksa `None`.
fn read_ipc() -> Option<IpcInfo> {
    let file = std::fs::File::open(store::data_dir().join(IPC_FILE)).ok()?;
    serde_json::from_reader::<_, IpcInfo>(file).ok()
}

/// Calisan ornek tek bir komut isledi mi? Pencereyi one getirmek gibi
/// yaniti umursamayan cagrilar icin.
pub fn notify_running(op: &str) -> bool {
    request(op, &serde_json::Value::Null).is_ok()
}

/// Onay penceresinin "baslat" karari: kayit yeri ve ad yazilir (gorev boylece
/// onaylanmis olur), `start` ile indirme hemen kuyruga alinir.
pub fn handoff_confirm(
    id: &str,
    dest_dir: &str,
    filename: &str,
    start: bool,
) -> Result<(), String> {
    request(
        "set_dest",
        &serde_json::json!({ "id": id, "destDir": dest_dir, "filename": filename }),
    )?;
    if start {
        request("resume", &serde_json::json!({ "id": id }))?;
    }
    Ok(())
}

/// Onay penceresinin "vazgec" karari: devralma listeden cikarilir.
pub fn handoff_cancel(id: &str) -> Result<(), String> {
    task_remove(id)
}

/// Indirme penceresinin gorunumu: tek gorevi (parcalariyla) calisan ornekten
/// ceker. Ikincil pencere kendi motorunu kurmadigi icin koprudan okur.
pub fn task_snapshot(id: &str) -> Result<Option<DownloadMeta>, String> {
    let payload = request("list", &serde_json::Value::Null)?;
    let tasks: Vec<DownloadMeta> =
        serde_json::from_value(payload).map_err(|_| "Gorev listesi okunamadi".to_string())?;
    Ok(tasks.into_iter().find(|task| task.id == id))
}

/// Indirme penceresinin "duraklat" karari.
pub fn task_pause(id: &str) -> Result<(), String> {
    request("pause", &serde_json::json!({ "id": id })).map(|_| ())
}

/// Indirme penceresinin "devam" karari.
pub fn task_resume(id: &str) -> Result<(), String> {
    request("resume", &serde_json::json!({ "id": id })).map(|_| ())
}

/// Indirme penceresinin "iptal" karari.
pub fn task_remove(id: &str) -> Result<(), String> {
    request("remove", &serde_json::json!({ "id": id })).map(|_| ())
}

/// Onay penceresinin kayit yeri/adi kararini motora uygular. Arayuzdeki
/// `set_task_dest` ile ayni dogrulamalari yineler: iki kabuk tek kural.
fn relocate(manager: &Arc<DownloadManager>, msg: &Incoming) -> Result<DownloadMeta, String> {
    let id = msg.id.clone().ok_or("id eksik")?;
    let dir = msg.dest_dir.clone().unwrap_or_default();
    let dir = dir.trim();
    if dir.is_empty() {
        return Err("Klasor yolu bos olamaz".into());
    }
    let name = engine::sanitize_filename(msg.filename.clone().unwrap_or_default().trim())
        .ok_or("Gecersiz dosya adi")?;
    manager.relocate(&id, Path::new(dir), &name)
}

async fn send_outcome(
    tx: &mpsc::Sender<String>,
    req_id: Option<String>,
    outcome: Result<(), String>,
) {
    match outcome {
        Ok(()) => {
            let _ = tx
                .send(
                    serde_json::json!({ "type": "ok", "reqId": req_id, "payload": {} }).to_string(),
                )
                .await;
        }
        Err(message) => {
            let _ = tx.send(error_message(req_id, &message)).await;
        }
    }
}

async fn serve(
    bridge: Arc<Bridge>,
    bus: EventBus,
    manager: Arc<DownloadManager>,
    stream: TcpStream,
) -> anyhow::Result<()> {
    let _ = stream.set_nodelay(true);
    let (read_half, write_half) = stream.into_split();
    let mut lines = BufReader::new(read_half).lines();
    let (tx, rx) = mpsc::channel::<String>(512);

    let writer = runtime::spawn(async move {
        let mut write_half = write_half;
        let mut rx = rx;
        while let Some(line) = rx.recv().await {
            if write_half.write_all(line.as_bytes()).await.is_err() {
                break;
            }
            if write_half.write_all(b"\n").await.is_err() {
                break;
            }
            if write_half.flush().await.is_err() {
                break;
            }
        }
    });

    let result = session(&bridge, &bus, &manager, &mut lines, &tx).await;

    drop(tx);
    let _ = writer.await;
    result
}

async fn session<R>(
    bridge: &Arc<Bridge>,
    bus: &EventBus,
    manager: &Arc<DownloadManager>,
    lines: &mut tokio::io::Lines<BufReader<R>>,
    tx: &mpsc::Sender<String>,
) -> anyhow::Result<()>
where
    R: tokio::io::AsyncRead + Unpin,
{
    // 1) El sikisma: ilk satir `hello` olmali ve token dogru olmali.
    let Some(first) = lines.next_line().await? else {
        return Ok(());
    };
    let hello: Incoming = serde_json::from_str(first.trim()).unwrap_or_default();

    if hello.kind != "hello" || hello.token.as_deref() != Some(bridge.info.token.as_str()) {
        let _ = tx.send(error_message(None, "gecersiz token")).await;
        return Ok(());
    }

    let _guard = ClientGuard::enter(&bridge.clients);

    let _ = tx
        .send(
            serde_json::json!({
                "type": "ready",
                "payload": { "version": bridge.info.version, "port": bridge.info.port },
            })
            .to_string(),
        )
        .await;

    // 2) Komut dongusu.
    let mut subscription: Option<tokio::task::JoinHandle<()>> = None;

    while let Some(line) = lines.next_line().await? {
        let text = line.trim();
        if text.is_empty() {
            continue;
        }

        let Ok(msg) = serde_json::from_str::<Incoming>(text) else {
            let _ = tx.send(error_message(None, "gecersiz JSON")).await;
            continue;
        };

        match msg.kind.as_str() {
            "ping" => {
                let _ = tx
                    .send(
                        serde_json::json!({
                            "type": "pong",
                            "reqId": msg.req_id.clone(),
                            "payload": {
                                "pid": bridge.info.pid,
                                "version": bridge.info.version,
                                "clients": bridge.clients(),
                            },
                        })
                        .to_string(),
                    )
                    .await;
            }
            "list" => {
                let _ = tx
                    .send(
                        serde_json::json!({
                            "type": "tasks",
                            "reqId": msg.req_id.clone(),
                            "payload": manager.snapshot(),
                        })
                        .to_string(),
                    )
                    .await;
            }
            "subscribe" => {
                let first_subscription = subscription.is_none();
                // Onay once yazilir, durum satirlari ardindan gelir; boylece
                // istemci `reqId` yankisini her zaman ilk hatta gorur.
                let _ = tx
                    .send(
                        serde_json::json!({
                            "type": "subscribed",
                            "reqId": msg.req_id.clone(),
                            "payload": {},
                        })
                        .to_string(),
                    )
                    .await;
                if first_subscription {
                    // Kanal istemcinin `subscribe` satiri islenirken kurulur:
                    // bu andan sonra olusan hicbir degisiklik kacmaz.
                    let mut events = bridge.events.subscribe();
                    let tx = tx.clone();
                    let manager = Arc::clone(manager);
                    subscription = Some(runtime::spawn(async move {
                        // Yeni abone motorun gosterdigi tam durumu beklemez:
                        // gorevler ve yakalananlar hemen gider, yoksa uygulama
                        // bos bir liste sanir. Satirlar kuyruk tasmasi
                        // yolundakilerle ayni (`state_lines`), ayri bir kural
                        // yoktur.
                        //
                        // Okuma kanal kurulduktan sonra yapilir; tam listede
                        // olmayan bir degisiklik bu yuzden kacamaz. Ayni anda
                        // olmus bir olay listede zaten vardir, en kotu
                        // ihtiyalle bir satir yinelenir - motor tek dogrudur,
                        // bir sonraki olay ya da `list` duzeltir.
                        //
                        // Okuma burada, ilerleyen kanalda degil: buyuk bir
                        // listenin okunmasi komut dongusunu bekletmez.
                        for line in state_lines(&manager) {
                            if tx.send(line).await.is_err() {
                                return;
                            }
                        }
                        // Ardisik tasmalarda (ornegin birikmis binlerce olay)
                        // saniyede bir toparlama gonderilir: durum her seferinde
                        // tam oldugu icin istemci ilk toparlamada yaklasir,
                        // kalanlar `list` istegi ya da bir sonraki tam liste
                        // ile kapanir.
                        let mut last_resync: Option<Instant> = None;
                        loop {
                            match events.recv().await {
                                Ok(message) => {
                                    if tx.send(message).await.is_err() {
                                        break;
                                    }
                                }
                                Err(broadcast::error::RecvError::Lagged(missed)) => {
                                    let now = Instant::now();
                                    if let Some(last) = last_resync {
                                        if now.duration_since(last) < RESYNC_MIN_GAP {
                                            continue;
                                        }
                                    }
                                    last_resync = Some(now);
                                    // Once acik bildirim, sonra motorun
                                    // gosterdigi tam durum: yarim paket asla
                                    // gonderilmez.
                                    let mut burst = vec![resync_line(missed)];
                                    burst.extend(state_lines(&manager));
                                    for line in burst {
                                        if tx.send(line).await.is_err() {
                                            return;
                                        }
                                    }
                                }
                                Err(_) => break,
                            }
                        }
                    }));
                } else {
                    // Ikinci ve sonraki `subscribe` yeni kanal kurmaz ama yine
                    // de tam durumu hatta gonderir; her abonelik ayni sonucu
                    // vermeli, istemci kendi durumunu sifirlamak zorunda
                    // kalmasin.
                    for line in state_lines(manager) {
                        if tx.send(line).await.is_err() {
                            break;
                        }
                    }
                }
            }
            "show" => {
                // Eklentinin "Serene'yi Ac" dugmesi: pencereyi one getir.
                bus.publish(CoreEvent::PresentWindow);
                let _ = tx
                    .send(
                        serde_json::json!({
                            "type": "ok",
                            "reqId": msg.req_id.clone(),
                            "payload": {},
                        })
                        .to_string(),
                    )
                    .await;
            }
            "enqueue" => {
                let req = msg.req_id.clone();
                match msg.url.clone() {
                    None => {
                        let _ = tx.send(error_message(req, "url eksik")).await;
                    }
                    Some(url) => {
                        let opts = enqueue::EnqueueOptions {
                            dest_dir: msg.dest_dir.clone(),
                            referer: msg.referer.clone(),
                            cookie: msg.cookie.clone(),
                            user_agent: msg.user_agent.clone(),
                            kind: msg.download_kind.unwrap_or_default(),
                            // Devralinan indirme kullanici onayina kadar bekler;
                            // medya yakalamalari dogrudan baslar.
                            hold: enqueue::should_hold(msg.source.as_deref(), &manager.settings()),
                            source: msg.source.clone(),
                        };
                        match enqueue::enqueue_download(manager, &url, opts).await {
                            Ok(task) => {
                                let _ = tx
                                    .send(
                                        serde_json::json!({
                                            "type": "ack",
                                            "reqId": req,
                                            "payload": task,
                                        })
                                        .to_string(),
                                    )
                                    .await;
                            }
                            Err(message) => {
                                let _ = tx.send(error_message(req, &message)).await;
                            }
                        }
                    }
                }
            }
            "capture" => {
                let req = msg.req_id.clone();
                match msg.url.clone() {
                    None => {
                        let _ = tx.send(error_message(req, "url eksik")).await;
                    }
                    Some(url) => {
                        // Adres `enqueue` ile ayni sekilde kanoniklestirilir;
                        // ayni medya iki kez listeye dusmesin.
                        let normalized =
                            enqueue::normalize_url(&url).unwrap_or_else(|_| url.trim().to_string());
                        let item = CaptureItem {
                            id: uuid::Uuid::new_v4().to_string(),
                            url: normalized,
                            filename: msg.filename.clone().unwrap_or_default(),
                            size: msg.size.unwrap_or(0),
                            content_type: msg.content_type.clone().unwrap_or_default(),
                            kind: msg.download_kind.unwrap_or_default(),
                            site: msg.site.clone().unwrap_or_default(),
                            created_at: now_secs(),
                        };
                        let stored = manager.add_capture(item);
                        if let Some(req) = req {
                            let _ = tx
                                .send(
                                    serde_json::json!({
                                        "type": "ack",
                                        "reqId": req,
                                        "payload": stored,
                                    })
                                    .to_string(),
                                )
                                .await;
                        }
                    }
                }
            }
            "list_captures" => {
                let _ = tx
                    .send(
                        serde_json::json!({
                            "type": "captures",
                            "reqId": msg.req_id.clone(),
                            "payload": manager.captures(),
                        })
                        .to_string(),
                    )
                    .await;
            }
            "download_capture" => {
                let req = msg.req_id.clone();
                match msg.id.clone() {
                    None => {
                        let _ = tx.send(error_message(req, "id eksik")).await;
                    }
                    Some(id) => match manager.capture(&id) {
                        None => {
                            let _ = tx.send(error_message(req, "Yakalama bulunamadi")).await;
                        }
                        Some(item) => {
                            let opts = enqueue::EnqueueOptions {
                                dest_dir: msg.dest_dir.clone(),
                                referer: None,
                                cookie: None,
                                user_agent: None,
                                kind: item.kind,
                                source: Some("capture".to_string()),
                                hold: false,
                            };
                            match enqueue::enqueue_download(manager, &item.url, opts).await {
                                Ok(task) => {
                                    let _ = tx
                                        .send(
                                            serde_json::json!({
                                                "type": "ack",
                                                "reqId": req,
                                                "payload": task,
                                            })
                                            .to_string(),
                                        )
                                        .await;
                                }
                                Err(message) => {
                                    let _ = tx.send(error_message(req, &message)).await;
                                }
                            }
                        }
                    },
                }
            }
            "set_dest" => {
                let req = msg.req_id.clone();
                match relocate(manager, &msg) {
                    Ok(meta) => {
                        let _ = tx
                            .send(
                                serde_json::json!({
                                    "type": "ack",
                                    "reqId": req,
                                    "payload": meta,
                                })
                                .to_string(),
                            )
                            .await;
                    }
                    Err(message) => {
                        let _ = tx.send(error_message(req, &message)).await;
                    }
                }
            }
            "resume" => {
                let req = msg.req_id.clone();
                let outcome = match msg.id.clone() {
                    None => Err("id eksik".to_string()),
                    Some(id) => manager.resume(&id),
                };
                send_outcome(tx, req, outcome).await;
            }
            "pause" => {
                let req = msg.req_id.clone();
                let outcome = match msg.id.clone() {
                    None => Err("id eksik".to_string()),
                    Some(id) => manager.pause(&id),
                };
                send_outcome(tx, req, outcome).await;
            }
            "dismiss_capture" => {
                let req = msg.req_id.clone();
                let outcome = match msg.id.clone() {
                    None => Err("id eksik".to_string()),
                    Some(id) => manager.dismiss_capture(&id),
                };
                send_outcome(tx, req, outcome).await;
            }
            "clear_captures" => {
                let req = msg.req_id.clone();
                manager.clear_captures();
                send_outcome(tx, req, Ok(())).await;
            }
            "remove" => {
                let req = msg.req_id.clone();
                let outcome = match msg.id.clone() {
                    None => Err("id eksik".to_string()),
                    Some(id) => manager.remove(&id, false),
                };
                send_outcome(tx, req, outcome).await;
            }
            other => {
                let _ = tx
                    .send(error_message(
                        msg.req_id.clone(),
                        &format!("bilinmeyen komut: {other}"),
                    ))
                    .await;
            }
        }
    }

    if let Some(handle) = subscription {
        handle.abort();
    }

    Ok(())
}
