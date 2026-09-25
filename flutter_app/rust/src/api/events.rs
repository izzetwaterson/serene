//! Cekirdek olay kutusunu Dart akislarina baglar.
//!
//! Her akis kutuya ayri bir abone olur; aboneler birbirinin olayini yemez.
//! Gorev listesi her yayinda tam liste olarak verilir, ilerleme ise yalnizca
//! inen gorevlerin hafif paketidir.
//!
//! Kuyruk tasmasi (`Lagged`) asla yutulmaz. Motor tek dogrudur, bu yuzden
//! tasma halinde durum yeniden okunur:
//!   * `Tasks` ve `Captures`: motorun anlik tam listesi gonderilir. Arayuz
//!     dogrudan motorun gosterdigi duruma doner.
//!   * `Progress`: paketin icine tasma bildirimi konur (`LOST_EVENTS_ID`),
//!     cunku bu akis yalnizca sayi tasir; Dart listeyi kendisi yeniler.
//!   * `HandoffPending`: motorun simdiki onay bekleyenleri yeniden gonderilir.
//!   * `ClipboardLink` ve `PresentWindow`: gecmis bir an, yeniden okunamaz;
//!     bunun yerine ayri bir kayit isareti gonderilir.
//!
//! `LOST_EVENTS_ID` gercek bir kimlikle carpisamaz: motor kimlikleri UUID
//! uretir, bu deger cift alt cizgiyle baslar. Dart tarafi ayni sabiti
//! `lostEventsId` adiyla tanir.
//!
//! Anlik tam liste, tamponda kalan olaylardan daha yenidir (okuma onlardan
//! sonra yapilir), bu yuzden toparlamadan sonra gelen olaylar arayuzu geri
//! almaz; en kotu halde ayni durumu tekrar yazar.

use std::sync::Arc;

use serene_core::bus::CoreEvent;
use serene_core::runtime;
use tokio::sync::broadcast::error::RecvError;

use crate::api::dto::{Capture, Progress, Task};
use crate::frb_generated::StreamSink;
use crate::state;

/// Yayindan dusmus olay bildirimi. Gercek kimlikler UUID oldugu icin bu
/// ayirici deger hicbir gorev ya da yakalama ile caprazlamaz.
/// Dart tarafi ayni degeri `lostEventsId` adiyla tanir.
const LOST_EVENTS_ID: &str = "__serene_lost__";

/// Panoya kopyalanan baglanti icin bildirim isareti; `http` olmayan tek deger.
/// Dart tarafi: `lostLink`.
const LOST_LINK: &str = "serene://lost";

/// `PresentWindow` icin bildirim isareti; gercek istek `1` ile gelir.
/// Dart tarafi: `lostPresent`.
const LOST_PRESENT: u32 = 0;

/// Kuyruk tasmasi motor seviyesinde bir arizadir: hem Dart'a bildirilir hem de
/// izde birakilir, sessizce yutulmaz.
fn note_lost(source: &str, missed: u64) {
    eprintln!("serene: {source} akisinda {missed} olay dusuldu, durum yeniden okunuyor");
}

/// Gercek bir gecmis sayimi `i64` sigacak kadar kucultulur.
fn count(missed: u64) -> i64 {
    missed.min(i64::MAX as u64) as i64
}

/// Tam gorev listesi degistiginde akar.
pub fn watch_tasks(sink: StreamSink<Vec<Task>>) -> Result<(), String> {
    let core = state::core()?;
    let mut rx = core.bus.subscribe();
    let manager = Arc::clone(&core.manager);
    runtime::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(CoreEvent::Tasks(tasks)) => {
                    let payload: Vec<Task> = tasks.into_iter().map(Task::from).collect();
                    if sink.add(payload).is_err() {
                        return;
                    }
                }
                Ok(_) => {}
                Err(RecvError::Lagged(missed)) => {
                    // Yarim liste gonderilmez; motorun gosterdigi tam liste
                    // gonderilir, boylece arayuz dogrudan dogrusu olur.
                    note_lost("gorev", missed);
                    let payload: Vec<Task> =
                        manager.snapshot().into_iter().map(Task::from).collect();
                    if sink.add(payload).is_err() {
                        return;
                    }
                }
                Err(_) => return,
            }
        }
    });
    Ok(())
}

/// Inen gorevlerin hiz/durum paketleri.
pub fn watch_progress(sink: StreamSink<Vec<Progress>>) -> Result<(), String> {
    let mut rx = state::core()?.bus.subscribe();
    runtime::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(CoreEvent::Progress(ticks)) => {
                    let payload: Vec<Progress> = ticks.into_iter().map(Progress::from).collect();
                    if sink.add(payload).is_err() {
                        return;
                    }
                }
                Ok(_) => {}
                Err(RecvError::Lagged(missed)) => {
                    // Bu akis gorev listesini tasiyamaz; tasmayi tek bir
                    // bildirimle bildirip Dart'in listeyi yeniden okumasini
                    // saglariz. Kayip paketin yarisi uygulanmaz.
                    note_lost("ilerleme", missed);
                    let signal = Progress {
                        id: LOST_EVENTS_ID.to_string(),
                        downloaded: count(missed),
                        total: 0,
                        speed: 0.0,
                    };
                    if sink.add(vec![signal]).is_err() {
                        return;
                    }
                }
                Err(_) => return,
            }
        }
    });
    Ok(())
}

/// Tarayicidan yakalanan medya listesi.
pub fn watch_captures(sink: StreamSink<Vec<Capture>>) -> Result<(), String> {
    let core = state::core()?;
    let mut rx = core.bus.subscribe();
    let manager = Arc::clone(&core.manager);
    runtime::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(CoreEvent::Captures(items)) => {
                    let payload: Vec<Capture> = items.into_iter().map(Capture::from).collect();
                    if sink.add(payload).is_err() {
                        return;
                    }
                }
                Ok(_) => {}
                Err(RecvError::Lagged(missed)) => {
                    // Yakalananlar da durumdur: motorun anlik listesi gider.
                    note_lost("yakalanan", missed);
                    let payload: Vec<Capture> =
                        manager.captures().into_iter().map(Capture::from).collect();
                    if sink.add(payload).is_err() {
                        return;
                    }
                }
                Err(_) => return,
            }
        }
    });
    Ok(())
}

/// Onay bekleyen tarayici devralmasi; harici pencere bunu dinler.
pub fn watch_handoff(sink: StreamSink<Task>) -> Result<(), String> {
    let core = state::core()?;
    let mut rx = core.bus.subscribe();
    let manager = Arc::clone(&core.manager);
    runtime::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(CoreEvent::HandoffPending(meta)) => {
                    if sink.add(meta.into()).is_err() {
                        return;
                    }
                }
                Ok(_) => {}
                Err(RecvError::Lagged(missed)) => {
                    // Onay bekleyen gorevler durumdur: motorun listesinden
                    // yeniden okunur, tahmin edilmez. Artik bekleyen yoksa
                    // bir sey gonderilmez; dustu bir devralma zaten onay
                    // beklemiyor demektir.
                    note_lost("onay", missed);
                    for meta in manager.snapshot().into_iter().filter(|m| m.pending) {
                        if sink.add(meta.into()).is_err() {
                            return;
                        }
                    }
                }
                Err(_) => return,
            }
        }
    });
    Ok(())
}

/// Panoya kopyalanan http(s) baglantisi.
pub fn watch_clipboard(sink: StreamSink<String>) -> Result<(), String> {
    let mut rx = state::core()?.bus.subscribe();
    runtime::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(CoreEvent::ClipboardLink(url)) => {
                    if sink.add(url).is_err() {
                        return;
                    }
                }
                Ok(_) => {}
                Err(RecvError::Lagged(missed)) => {
                    // Kopyalanan adres bir andir; geriye donuk okunamaz. Bunun
                    // yerine kayit isareti gider, arayuz baglantiyi uydurmaz.
                    note_lost("pano", missed);
                    if sink.add(LOST_LINK.to_string()).is_err() {
                        return;
                    }
                }
                Err(_) => return,
            }
        }
    });
    Ok(())
}

/// Eklentinin "Serene'yi one getir" istegi; her istek bir tik uretir.
pub fn watch_present(sink: StreamSink<u32>) -> Result<(), String> {
    let mut rx = state::core()?.bus.subscribe();
    runtime::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(CoreEvent::PresentWindow) => {
                    if sink.add(1).is_err() {
                        return;
                    }
                }
                Ok(_) => {}
                Err(RecvError::Lagged(missed)) => {
                    // Dusen istek "pencereyi one getir" sayilmaz: bildirim
                    // `0` ile gider, arayuz yanlis yere one getirmez.
                    note_lost("pencere", missed);
                    if sink.add(LOST_PRESENT).is_err() {
                        return;
                    }
                }
                Err(_) => return,
            }
        }
    });
    Ok(())
}
