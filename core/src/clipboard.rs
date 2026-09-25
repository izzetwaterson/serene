use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crate::bus::{CoreEvent, EventBus};

/// Yoklama araligi. Pano bir iletisim kutusu; surekli dinlemek mumkun
/// olsa da 900 ms kullanici farkini etmez, pil dostu ve yeterlidir.
const POLL_INTERVAL_MS: u64 = 900;

/// Geri cekilmenin baslangic ve tavan degeri. Pano baska bir surec
/// tarafindan kilitlendiginde saniyeler icinde acilir; bu yuzden bekleme
/// kisa tutulur, birkac denemeden sonra tavana dayanir.
const RETRY_BASE_MS: u64 = 500;
const RETRY_MAX_MS: u64 = 15_000;

/// Kac ardisik hatadan sonra kullaniciya bir kez uyari basilir. Onceki
/// surum bu noktada sessizce is parcacigini olduruyordu.
const WARN_AFTER: u32 = 5;

/// Panoyu bir kez okur.
///
/// Tutmak uzun sure fayda saglamaz: baska uygulama pano kilitlediginde ya
/// da oturum degistiginde bayat tutamac hep ayni hatayi doner. Bu yuzden
/// eldeki tutamac once kullanilir, hatada birakilir ve sonraki denemede
/// yenisi kurulur.
fn read_clipboard(handle: &mut Option<arboard::Clipboard>) -> Result<String, String> {
    if let Some(clipboard) = handle.as_mut() {
        match clipboard.get_text() {
            Ok(text) => return Ok(text),
            Err(err) => {
                *handle = None;
                return Err(err.to_string());
            }
        }
    }

    let mut clipboard = arboard::Clipboard::new().map_err(|err| err.to_string())?;
    match clipboard.get_text() {
        Ok(text) => {
            *handle = Some(clipboard);
            Ok(text)
        }
        // Yeni kurulan tutamak da okuyamadisa birakilir; sonraki denemede
        // tekrar kurulur.
        Err(err) => Err(err.to_string()),
    }
}

/// Pano izleyicisinin hata halindeki karari. Saf: gercek pano olmadan da
/// test edilebilir.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RetryDecision {
    /// Yeniden denemeden once beklenecek sure.
    pub wait: Duration,
    /// Bu denemede kullaniciya uyari basilmali mi.
    pub warn: bool,
}

/// `consecutive_failures` ardisik hatadan sonraki karar.
///
/// Bekleme geometrik olarak artar ve `RETRY_MAX_MS`de tavana dayanir; is
/// parcacigi hicbir zaman vazgecmeyi secmez, yalnizca daha seyrek dener.
/// `warn` yalnizca esik degerde `true` olur, cagiran bir kez basip
/// kilitledigi icin ayni uyari tekrarlanmaz.
pub fn retry_decision(consecutive_failures: u32) -> RetryDecision {
    if consecutive_failures == 0 {
        return RetryDecision {
            wait: Duration::ZERO,
            warn: false,
        };
    }
    let step = consecutive_failures.saturating_sub(1).min(16);
    let wait = RETRY_BASE_MS.saturating_mul(1u64 << step).min(RETRY_MAX_MS);
    RetryDecision {
        wait: Duration::from_millis(wait),
        warn: consecutive_failures >= WARN_AFTER,
    }
}

/// Panoyu yoklar; yeni bir http(s) baglantisi gorunce arayuze haber verir.
/// Kullaniciya "Yakalanan baglanti" karti gostermek icin kullanilir; hicbir
/// indirme kendiliginden baslatilmaz.
///
/// Pano baska bir uygulama tarafindan kilitliyse ya da oturum degistiyse
/// is parcacigi olmez: hatayi sayar, bekleyip yeniden dener ve cok suredir
/// acilamiyorsa bir kez uyari basar.
pub fn spawn_watcher(bus: EventBus, enabled: Arc<AtomicBool>) {
    std::thread::spawn(move || {
        let mut last_seen: Option<String> = None;
        let mut handle: Option<arboard::Clipboard> = None;
        let mut failures: u32 = 0;
        let mut warned = false;

        loop {
            std::thread::sleep(Duration::from_millis(POLL_INTERVAL_MS));

            if !enabled.load(Ordering::Relaxed) {
                continue;
            }

            match read_clipboard(&mut handle) {
                Ok(text) => {
                    failures = 0;
                    warned = false;
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
                Err(err) => {
                    failures = failures.saturating_add(1);
                    let decision = retry_decision(failures);
                    if decision.warn && !warned {
                        warned = true;
                        eprintln!(
                            "[pano] {failures} kez okunamadi ({err}); pano izleme askida, \
                             yeniden denenecek"
                        );
                    }
                    std::thread::sleep(decision.wait);
                }
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
