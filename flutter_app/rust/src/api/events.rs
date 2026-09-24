//! Cekirdek olay kutusunu Dart akislarina baglar.
//!
//! Her akis kutuya ayri bir abone olur; aboneler birbirinin olayini yemez.
//! Gorev listesi her yayinda tam liste olarak verilir, ilerleme ise yalnizca
//! inen gorevlerin hafif paketidir.

use serene_core::bus::CoreEvent;
use tokio::sync::broadcast::error::RecvError;
use serene_core::runtime;

use crate::api::dto::{Capture, Progress, Task};
use crate::frb_generated::StreamSink;
use crate::state;

/// Tam gorev listesi degistiginde akar.
pub fn watch_tasks(sink: StreamSink<Vec<Task>>) -> Result<(), String> {
    let mut rx = state::core()?.bus.subscribe();
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
                Err(RecvError::Lagged(_)) => {}
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
                Err(RecvError::Lagged(_)) => {}
                Err(_) => return,
            }
        }
    });
    Ok(())
}

/// Tarayicidan yakalanan medya listesi.
pub fn watch_captures(sink: StreamSink<Vec<Capture>>) -> Result<(), String> {
    let mut rx = state::core()?.bus.subscribe();
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
                Err(RecvError::Lagged(_)) => {}
                Err(_) => return,
            }
        }
    });
    Ok(())
}

/// Onay bekleyen tarayici devralmasi; harici pencere bunu dinler.
pub fn watch_handoff(sink: StreamSink<Task>) -> Result<(), String> {
    let mut rx = state::core()?.bus.subscribe();
    runtime::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(CoreEvent::HandoffPending(meta)) => {
                    if sink.add(meta.into()).is_err() {
                        return;
                    }
                }
                Ok(_) => {}
                Err(RecvError::Lagged(_)) => {}
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
                Err(RecvError::Lagged(_)) => {}
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
                Err(RecvError::Lagged(_)) => {}
                Err(_) => return,
            }
        }
    });
    Ok(())
}
