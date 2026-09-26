//! Cekirdek olay kutusu.
//!
//! Motor durum degistiginde buraya yayinlar; kabugun kendisi (Tauri ya da
//! Flutter) dinleyip kendi arayuz kanalina cevirir. Boylece motor hicbir
//! arayuz kutuphanesine bakmaz.

use tokio::sync::broadcast;

use crate::manager::ProgressTick;
use crate::models::{CaptureItem, DownloadMeta};

/// Kutu kapasitesi. Kalp atisi 400 ms'de bir (saniyede 2-5 olay), yani 1024
/// yuva bir dinleyici yaklasik uc dakika boyunca hic okumasa bile tum olaylari
/// alir. Bu yalnizca tampon; asil duzeltme dinleyici yine de tasirsa
/// `Lagged` sonucunun gizlenmemesidir.
const CAPACITY: usize = 1024;

#[derive(Clone)]
pub enum CoreEvent {
    /// Tum gorev listesi (arayuz tabloyu bastan cizir).
    Tasks(Vec<DownloadMeta>),
    /// Yalnizca inen gorevlerin hafif ilerleme paketi.
    Progress(Vec<ProgressTick>),
    /// Tarayicidan yakalanan medya listesi.
    Captures(Vec<CaptureItem>),
    /// Onay penceresinin acmasini isteyen tarayici devralmasi.
    HandoffPending(DownloadMeta),
    /// Panoya kopyalanan ve indirilmesi onerilen baglanti.
    ClipboardLink(String),
    /// Eklentinin "Serene'yi Ac" dugmesi: kabuk pencereyi one getirmeli.
    PresentWindow,
    /// Durum dosyasi yazilamadi. Kullanici verisini kaybetmek en kotu hata
    /// sinifidir, bu yuzden sessizce yutulmaz: arayuz uyari gosterir.
    StorageError(String),
}

#[derive(Clone)]
pub struct EventBus {
    tx: broadcast::Sender<CoreEvent>,
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new()
    }
}

impl EventBus {
    pub fn new() -> Self {
        let (tx, _) = broadcast::channel(CAPACITY);
        Self { tx }
    }

    /// Dinleyici yoksa sesiz gecilir: motor, arayuzun acik olup olmadigini
    /// bilmez ve umursamaz.
    pub fn publish(&self, event: CoreEvent) {
        let _ = self.tx.send(event);
    }

    pub fn subscribe(&self) -> broadcast::Receiver<CoreEvent> {
        self.tx.subscribe()
    }
}
