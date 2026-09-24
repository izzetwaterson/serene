use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crate::bus::{CoreEvent, EventBus};

/// Panoyu yoklar; yeni bir http(s) baglantisi gorunce arayuze haber verir.
/// Kullaniciya "Yakalanan baglanti" karti gostermek icin kullanilir; hicbir
/// indirme kendiliginden baslatilmaz.
pub fn spawn_watcher(bus: EventBus, enabled: Arc<AtomicBool>) {
    std::thread::spawn(move || {
        let mut clipboard = match arboard::Clipboard::new() {
            Ok(clipboard) => clipboard,
            Err(_) => return,
        };

        let mut last_seen: Option<String> = None;

        loop {
            std::thread::sleep(Duration::from_millis(900));

            if !enabled.load(Ordering::Relaxed) {
                continue;
            }

            let Ok(text) = clipboard.get_text() else {
                continue;
            };
            if text.is_empty() || text.len() > 4096 {
                continue;
            }
            if last_seen.as_deref() == Some(text.as_str()) {
                continue;
            }
            last_seen = Some(text.clone());

            if let Some(url) = extract_url(&text) {
                bus.publish(CoreEvent::ClipboardLink(url));
            }
        }
    });
}

/// Metnin icinden ilk http(s) baglantisini cikarir.
pub fn extract_url(text: &str) -> Option<String> {
    text.split_whitespace()
        .map(|token| {
            token.trim_matches(|c: char| {
                matches!(c, '"' | '\'' | '<' | '>' | '(' | ')' | '[' | ']' | ',' | ';')
            })
        })
        .find(|token| token.starts_with("http://") || token.starts_with("https://"))
        .map(|token| token.to_string())
}
