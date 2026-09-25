use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use reqwest::Client;
use serde::Serialize;
use tokio_util::sync::CancellationToken;

use crate::bus::{CoreEvent, EventBus};
use crate::category;
use crate::dash;
use crate::engine;
use crate::hls;
use crate::models::{CaptureItem, DownloadKind, DownloadMeta, Settings, Status};
use crate::platform;
use crate::runtime;
use crate::store;

/// Her kosuda degisen, serilestirilmeyen gorev durumu.
pub struct DownloadEntry {
    pub id: String,
    pub meta: Mutex<DownloadMeta>,
    /// Parca basina canli bayt sayaci (motor doldurur).
    pub parts: Mutex<Vec<Arc<AtomicU64>>>,
    /// Motor baslamadan once diskte zaten duran bayt miktari.
    pub base_bytes: AtomicU64,
    pub rate: Mutex<RateMeter>,
}

#[derive(Default)]
pub struct RateMeter {
    last_bytes: u64,
    last_at: Option<Instant>,
    speed: f64,
}

impl DownloadEntry {
    pub fn new(meta: DownloadMeta) -> Self {
        Self {
            id: meta.id.clone(),
            meta: Mutex::new(meta),
            parts: Mutex::new(Vec::new()),
            base_bytes: AtomicU64::new(0),
            rate: Mutex::new(RateMeter::default()),
        }
    }

    /// Parca sayaclarini bilinen ilerlemeden tohumlar; boylece motor hazirlanirken
    /// arayuzdeki ilerleme sifira dusmez.
    fn seed_counters(&self) {
        let meta = self.meta.lock().unwrap();
        let counters: Vec<Arc<AtomicU64>> = meta
            .segments
            .iter()
            .map(|_| Arc::new(AtomicU64::new(0)))
            .collect();
        self.base_bytes
            .store(meta.segments.iter().map(|s| s.downloaded).sum(), Ordering::Relaxed);
        *self.parts.lock().unwrap() = counters;
        *self.rate.lock().unwrap() = RateMeter::default();
    }
}

struct Inner {
    /// Gorunum sirasi: en yeni is basta.
    order: Vec<String>,
    entries: HashMap<String, Arc<DownloadEntry>>,
    running: HashMap<String, CancellationToken>,
    dirty: bool,
}

/// Arayuze gonderilen hafif ilerleme paketi.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgressTick {
    pub id: String,
    pub downloaded: u64,
    pub total: u64,
    pub speed: f64,
}

pub struct DownloadManager {
    bus: EventBus,
    client: Client,
    tasks_path: PathBuf,
    settings_path: PathBuf,
    /// Tarayicidan yakalananlar; gorevlerden ayri dosyada tutulur ki ikisi de
    /// birbirinin temizlenmesinden etkilenmesin.
    capture_path: PathBuf,
    clipboard_enabled: Arc<AtomicBool>,
    inner: Mutex<Inner>,
    settings: Mutex<Settings>,
    captures: Mutex<Vec<CaptureItem>>,
}

impl DownloadManager {
    pub fn new(bus: EventBus) -> anyhow::Result<Arc<Self>> {
        let dir = store::data_dir();
        std::fs::create_dir_all(&dir).ok();

        let tasks_path = dir.join("tasks.json");
        let settings_path = dir.join("settings.json");
        let capture_path = dir.join("captures.json");

        let settings = store::load_settings(&settings_path);
        let restored = store::load_tasks(&tasks_path);
        let captures = store::load_captures(&capture_path);

        let mut order = Vec::with_capacity(restored.len());
        let mut entries = HashMap::with_capacity(restored.len());
        for meta in restored {
            order.push(meta.id.clone());
            entries.insert(meta.id.clone(), Arc::new(DownloadEntry::new(meta)));
        }

        Ok(Arc::new(Self {
            bus,
            client: engine::build_client()?,
            tasks_path,
            settings_path,
            capture_path,
            clipboard_enabled: Arc::new(AtomicBool::new(settings.watch_clipboard)),
            inner: Mutex::new(Inner {
                order,
                entries,
                running: HashMap::new(),
                dirty: false,
            }),
            settings: Mutex::new(settings),
            captures: Mutex::new(captures),
        }))
    }

    pub fn client(&self) -> Client {
        self.client.clone()
    }

    pub fn connections(&self) -> usize {
        self.settings.lock().unwrap().connections
    }

    pub fn settings(&self) -> Settings {
        self.settings.lock().unwrap().clone()
    }

    pub fn clipboard_flag(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.clipboard_enabled)
    }

    pub fn update_settings(self: &Arc<Self>, next: Settings) {
        self.clipboard_enabled
            .store(next.watch_clipboard, Ordering::Relaxed);
        // Otomatik baslatma ayar dosyasinda durur ama gercek etkisini kayit
        // defterindeki Run anahtari yazar; ikisi birlikte degismeli. Kurulum
        // paketi de ayni anahtari yazdigindan tek dogruluk kaynagi bu degil,
        // etkileyen tek yol.
        if let Err(err) = platform::set_autostart(next.autostart) {
            eprintln!(
                "[depo] otomatik baslatma anahtari yazilamadi: {err}"
            );
        }
        store::save_settings(&self.settings_path, &next);
        *self.settings.lock().unwrap() = next;
        self.pump();
    }

    pub fn snapshot(&self) -> Vec<DownloadMeta> {
        let inner = self.inner.lock().unwrap();
        inner
            .order
            .iter()
            .filter_map(|id| inner.entries.get(id))
            .map(|e| e.meta.lock().unwrap().clone())
            .collect()
    }

    pub fn find(&self, id: &str) -> Option<Arc<DownloadEntry>> {
        self.inner.lock().unwrap().entries.get(id).cloned()
    }

    /* ---------- Tarayicidan yakalananlar (Faz 7) ---------- */

    /// Yakalananlar listesi; en yeni kayit basta.
    pub fn captures(&self) -> Vec<CaptureItem> {
        self.captures.lock().unwrap().clone()
    }

    pub fn capture(&self, id: &str) -> Option<CaptureItem> {
        self.captures
            .lock()
            .unwrap()
            .iter()
            .find(|item| item.id == id)
            .cloned()
    }

    /// Yeni yakalama. Ayni url zaten kayitliysa mevcut kayit doner; liste
    /// degismedigi icin olay da yayinlanmaz (id sabit kalir).
    pub fn add_capture(&self, item: CaptureItem) -> CaptureItem {
        let (stored, inserted) = {
            let mut items = self.captures.lock().unwrap();
            store::upsert_capture(&mut items, item)
        };
        if inserted {
            self.persist_captures();
            self.emit_captures();
        }
        stored
    }

    pub fn dismiss_capture(&self, id: &str) -> Result<(), String> {
        let removed = {
            let mut items = self.captures.lock().unwrap();
            let before = items.len();
            items.retain(|item| item.id != id);
            items.len() != before
        };
        if !removed {
            return Err("Yakalama bulunamadi".into());
        }
        self.persist_captures();
        self.emit_captures();
        Ok(())
    }

    pub fn clear_captures(&self) -> usize {
        let count = {
            let mut items = self.captures.lock().unwrap();
            let count = items.len();
            items.clear();
            count
        };
        if count > 0 {
            self.persist_captures();
            self.emit_captures();
        }
        count
    }

    fn persist_captures(&self) {
        let items = self.captures.lock().unwrap();
        store::save_captures(&self.capture_path, &items);
    }

    /// Arayuz ve kopru icin tam liste olayi; `tasks:update` ile ayni kural.
    pub fn emit_captures(&self) {
        self.bus.publish(CoreEvent::Captures(self.captures()));
    }

    pub fn emit_full(&self) {
        self.bus.publish(CoreEvent::Tasks(self.snapshot()));
    }

    /// Onay penceresinin acilmasini isteyen devralma. Kabuk bu olayi görünür
    /// bir pencereye cevirir; motor pencere kavramini bilmez.
    pub fn emit_handoff(&self, meta: &DownloadMeta) {
        self.bus.publish(CoreEvent::HandoffPending(meta.clone()));
    }

    pub fn insert(&self, meta: DownloadMeta) -> Arc<DownloadEntry> {
        let entry = Arc::new(DownloadEntry::new(meta));
        {
            let mut inner = self.inner.lock().unwrap();
            inner.order.insert(0, entry.id.clone());
            inner.entries.insert(entry.id.clone(), Arc::clone(&entry));
            inner.dirty = true;
        }
        entry
    }

    /// Bos yuva oldugu surece en eski bekleyen isleri baslatir.
    pub fn pump(self: &Arc<Self>) {
        let max = self.settings.lock().unwrap().max_concurrent.max(1);
        let mut to_start: Vec<String> = Vec::new();

        {
            let mut inner = self.inner.lock().unwrap();
            let mut slots = max.saturating_sub(inner.running.len());
            if slots == 0 {
                return;
            }

            for id in inner.order.iter().rev() {
                if slots == 0 {
                    break;
                }
                if inner.running.contains_key(id) {
                    continue;
                }
                let Some(entry) = inner.entries.get(id) else {
                    continue;
                };
                if entry.meta.lock().unwrap().status == Status::Queued {
                    to_start.push(id.clone());
                    slots -= 1;
                }
            }

            for id in &to_start {
                inner.running.insert(id.clone(), CancellationToken::new());
            }
        }

        for id in &to_start {
            let (entry, cancel) = {
                let inner = self.inner.lock().unwrap();
                let Some(entry) = inner.entries.get(id).cloned() else {
                    continue;
                };
                let Some(cancel) = inner.running.get(id).cloned() else {
                    continue;
                };
                (entry, cancel)
            };

            entry.seed_counters();
            entry.meta.lock().unwrap().status = Status::Downloading;

            let kind = entry.meta.lock().unwrap().kind;
            let mgr = Arc::clone(self);
            runtime::spawn(async move {
                match kind {
                    DownloadKind::File => engine::run(mgr, entry, cancel).await,
                    DownloadKind::Hls => hls::run(mgr, entry, cancel).await,
                    DownloadKind::Dash => dash::run(mgr, entry, cancel).await,
                }
            });
        }

        if !to_start.is_empty() {
            self.emit_full();
        }
    }

    pub fn on_task_stopped(self: &Arc<Self>, id: &str) {
        {
            let mut inner = self.inner.lock().unwrap();
            inner.running.remove(id);
            inner.dirty = true;
        }
        if let Some(entry) = self.find(id) {
            *entry.parts.lock().unwrap() = Vec::new();
            entry.base_bytes.store(0, Ordering::Relaxed);
            *entry.rate.lock().unwrap() = RateMeter::default();
        }
        self.emit_full();
        self.persist_now();
        self.pump();
    }

    pub fn pause(&self, id: &str) -> Result<(), String> {
        let (entry, cancel) = {
            let inner = self.inner.lock().unwrap();
            let entry = inner.entries.get(id).cloned().ok_or("Gorev bulunamadi")?;
            (entry, inner.running.get(id).cloned())
        };

        {
            let mut meta = entry.meta.lock().unwrap();
            if meta.status == Status::Completed {
                return Err("Tamamlanan indirme duraklatilamaz".into());
            }
            meta.status = Status::Paused;
            meta.speed = 0.0;
        }

        if let Some(token) = cancel {
            token.cancel();
        }
        self.emit_full();
        self.persist_now();
        Ok(())
    }

    /// Su an inen tum gorevleri duraklatir; kac tanesinin durdugunu doner.
    pub fn pause_all(&self) -> usize {
        let ids: Vec<String> = {
            let inner = self.inner.lock().unwrap();
            inner
                .order
                .iter()
                .filter(|id| {
                    inner
                        .entries
                        .get(*id)
                        .map(|e| e.meta.lock().unwrap().status == Status::Downloading)
                        .unwrap_or(false)
                })
                .cloned()
                .collect()
        };

        ids.iter().filter(|id| self.pause(id).is_ok()).count()
    }

    pub fn resume(self: &Arc<Self>, id: &str) -> Result<(), String> {
        {
            let entry = self.find(id).ok_or("Gorev bulunamadi")?;
            let mut meta = entry.meta.lock().unwrap();
            if meta.status == Status::Completed {
                return Err("Indirme zaten tamamlandi".into());
            }
            if meta.status == Status::Downloading {
                return Ok(());
            }
            meta.status = Status::Queued;
            meta.pending = false;
            meta.error = None;
            meta.speed = 0.0;
        }
        self.emit_full();
        self.pump();
        Ok(())
    }

    /// Baslamamis bir gorevin kayit yerini ve dosya adini degistirir.
    /// Indirilmis bayt varsa parcalar yeni yola tasinmayacagi icin reddedilir.
    pub fn relocate(
        self: &Arc<Self>,
        id: &str,
        dir: &Path,
        filename: &str,
    ) -> Result<DownloadMeta, String> {
        std::fs::create_dir_all(dir).map_err(|e| format!("Klasor olusturulamadi: {e}"))?;

        let entry = self.find(id).ok_or("Gorev bulunamadi")?;
        let snapshot = {
            let mut meta = entry.meta.lock().unwrap();
            if meta.downloaded > 0 {
                return Err("Indirme basladiktan sonra kayit yeri degistirilemez".into());
            }
            if !matches!(meta.status, Status::Queued | Status::Paused) {
                return Err("Bu gorev icin kayit yeri degistirilemez".into());
            }

            let dest = engine::unique_dest(dir, filename);
            let name = dest
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("indirme")
                .to_string();
            let temp_dir = dir.join(".serene").join(&meta.id);

            meta.filename = name;
            meta.dest = dest.to_string_lossy().to_string();
            meta.temp_dir = temp_dir.to_string_lossy().to_string();
            meta.category = category::classify(&meta.filename);
            meta.pending = false;
            meta.clone()
        };

        self.emit_full();
        self.persist_now();
        Ok(snapshot)
    }

    pub fn retry(self: &Arc<Self>, id: &str) -> Result<(), String> {
        {
            let entry = self.find(id).ok_or("Gorev bulunamadi")?;
            let mut meta = entry.meta.lock().unwrap();
            if meta.status == Status::Completed {
                return Err("Indirme zaten tamamlandi".into());
            }
            // Onceki deneme basarisiz olduysa segment planini sifirla ki
            // boyut/aralik bilgisi bastan alinsin.
            meta.segments.clear();
            meta.total = 0;
            meta.resumable = false;
            meta.status = Status::Queued;
            meta.error = None;
            meta.downloaded = 0;
            meta.speed = 0.0;
        }
        if let Some(entry) = self.find(id) {
            let temp = entry.meta.lock().unwrap().temp_dir.clone();
            let _ = std::fs::remove_dir_all(temp);
        }
        self.emit_full();
        self.pump();
        Ok(())
    }

    pub fn remove(self: &Arc<Self>, id: &str, delete_file: bool) -> Result<(), String> {
        let (entry, cancel) = {
            let mut inner = self.inner.lock().unwrap();
            let entry = inner.entries.remove(id).ok_or("Gorev bulunamadi")?;
            let cancel = inner.running.remove(id);
            inner.order.retain(|x| x != id);
            inner.dirty = true;
            (entry, cancel)
        };

        if let Some(token) = cancel {
            token.cancel();
        }

        let (temp, dest) = {
            let meta = entry.meta.lock().unwrap();
            (
                PathBuf::from(&meta.temp_dir),
                PathBuf::from(&meta.dest),
            )
        };

        // Motorun dosya tutamaclarini birakmasi icin kisa bir pencere birak.
        runtime::spawn(async move {
            tokio::time::sleep(Duration::from_millis(400)).await;
            let _ = tokio::fs::remove_dir_all(&temp).await;
            // Yarim kalan islerde nihai dosya henuz olusmamis olur; dosya
            // silme istegi asil olarak tamamlanmis indirmeler icin anlamli.
            if delete_file {
                let _ = tokio::fs::remove_file(&dest).await;
            }
        });

        self.emit_full();
        self.persist_now();
        self.pump();
        Ok(())
    }

    pub fn clear_completed(self: &Arc<Self>) -> usize {
        let ids: Vec<String> = {
            let inner = self.inner.lock().unwrap();
            inner
                .order
                .iter()
                .filter(|id| {
                    inner
                        .entries
                        .get(*id)
                        .map(|e| e.meta.lock().unwrap().status == Status::Completed)
                        .unwrap_or(false)
                })
                .cloned()
                .collect()
        };

        if !ids.is_empty() {
            let mut inner = self.inner.lock().unwrap();
            for id in &ids {
                inner.entries.remove(id);
            }
            inner.order.retain(|id| !ids.contains(id));
            inner.dirty = true;
        }

        self.emit_full();
        self.persist_now();
        ids.len()
    }

    /// Ilerlemeyi guncelleyip arayuze hafif bir paket doner.
    pub fn refresh_and_collect(&self) -> Vec<ProgressTick> {
        let inner = self.inner.lock().unwrap();
        let mut ticks = Vec::with_capacity(inner.running.len());

        for id in inner.running.keys() {
            let Some(entry) = inner.entries.get(id) else {
                continue;
            };
            let mut meta = entry.meta.lock().unwrap();
            if meta.status != Status::Downloading {
                continue;
            }

            {
                let parts = entry.parts.lock().unwrap();
                if !parts.is_empty() {
                    let live: u64 = parts.iter().map(|p| p.load(Ordering::Relaxed)).sum();
                    meta.downloaded = entry.base_bytes.load(Ordering::Relaxed) + live;
                    for (i, p) in parts.iter().enumerate() {
                        if let Some(seg) = meta.segments.get_mut(i) {
                            seg.downloaded = p.load(Ordering::Relaxed);
                        }
                    }
                }
            }

            {
                let mut rate = entry.rate.lock().unwrap();
                let now = Instant::now();
                match rate.last_at {
                    Some(prev) => {
                        let dt = now.duration_since(prev).as_secs_f64();
                        if dt >= 0.2 {
                            let delta = meta.downloaded.saturating_sub(rate.last_bytes) as f64;
                            let instant = delta / dt;
                            rate.speed = if rate.speed > 0.0 {
                                rate.speed * 0.6 + instant * 0.4
                            } else {
                                instant
                            };
                            rate.last_bytes = meta.downloaded;
                            rate.last_at = Some(now);
                        }
                    }
                    None => {
                        rate.last_at = Some(now);
                        rate.last_bytes = meta.downloaded;
                    }
                }
                meta.speed = rate.speed;
            }

            ticks.push(ProgressTick {
                id: meta.id.clone(),
                downloaded: meta.downloaded,
                total: meta.total,
                speed: meta.speed,
            });
        }

        ticks
    }

    pub fn emit_progress(&self) {
        let ticks = self.refresh_and_collect();
        if !ticks.is_empty() {
            self.bus.publish(CoreEvent::Progress(ticks));
        }
    }

    pub fn take_dirty(&self) -> bool {
        let mut inner = self.inner.lock().unwrap();
        std::mem::replace(&mut inner.dirty, false)
    }

    pub fn persist_now(&self) {
        store::save_tasks(&self.tasks_path, &self.snapshot());
    }

    /// Arayuzu canli tutan kalp atisi: hiz olcumu, ilerleme yayini, kuyruk besleme.
    pub fn spawn_ticker(mgr: Arc<Self>) {
        runtime::spawn(async move {
            let mut tick: u64 = 0;
            loop {
                tokio::time::sleep(Duration::from_millis(400)).await;
                tick += 1;

                mgr.emit_progress();

                if tick % 10 == 0 {
                    mgr.persist_now();
                }

                if mgr.take_dirty() {
                    mgr.emit_full();
                }

                mgr.pump();
            }
        });
    }
}
