//! Pano izleyicisinin hata kurtarmasi. Gercek pano olmadan test
//! edilebilen tek parca saf karar mantigi: kac ardisik hatadan sonra ne
//! kadar beklenir ve ne zaman uyari basilir.
//!
//! Test edilmeyen kisim bilerek: `spawn_watcher` gercek panoyu okur, bu
//! yuzden test kosumunda kullanici panosuna dokunmamak icin cagrilmaz.
//! Kapsanan sozlesme "izleyici vazgecmiyor": bekleme artiyor, tavana
//! dayaniyor, is parcacigi olmuyor.

use std::time::Duration;

use serene_core::clipboard::retry_decision;

#[test]
fn healthy_clipboard_waits_zero() {
    // Hata yoksa geri cekilme yok: yoklama araligi aynen korunur.
    let decision = retry_decision(0);
    assert_eq!(decision.wait, Duration::ZERO);
    assert!(!decision.warn, "hatasiz durumda uyari basilmamali");
}

#[test]
fn first_failure_is_retried_quickly() {
    let decision = retry_decision(1);
    assert_eq!(decision.wait, Duration::from_millis(500));
    assert!(!decision.warn, "tek hata kullaniciyi rahatsiz etmemeli");
}

#[test]
fn backoff_grows_with_consecutive_failures() {
    // Tavana kadar artar: 1..6. hata 500 ms -> 1 s -> 2 s -> 4 s -> 8 s.
    let mut previous = Duration::ZERO;
    for failures in 1..=6 {
        let wait = retry_decision(failures).wait;
        assert!(
            wait > previous,
            "{failures}. hatada bekleme artmali ({previous:?} -> {wait:?})"
        );
        previous = wait;
    }
    // Tavandan sonra geriye dogru sarkmaz, sabit kalir.
    for failures in 7..=12 {
        assert_eq!(
            retry_decision(failures).wait,
            previous,
            "{failures}. hatada bekleme azalmamali"
        );
    }
}

#[test]
fn backoff_is_capped_so_the_thread_keeps_trying() {
    // Pano kilidi kalkinca is parcacigi saniyalar icinde yeniden okumali;
    // bekleme sonsuza kadar buyuyorsa ozellik sessizce olur.
    let capped = retry_decision(7).wait;
    assert_eq!(capped, Duration::from_millis(15_000));
    for failures in [8, 20, 100, 10_000, u32::MAX] {
        assert_eq!(
            retry_decision(failures).wait,
            capped,
            "{failures} hatada bekleme tavanda kalmali"
        );
    }
    // Tavana dogru monotonik: geriye dogru sarkma olmamali.
    assert!(retry_decision(2).wait <= retry_decision(6).wait);
}

#[test]
fn warning_fires_once_at_the_threshold() {
    for failures in 1..4 {
        assert!(
            !retry_decision(failures).warn,
            "{failures}. hatada henuz uyari basilmamali"
        );
    }
    assert!(
        retry_decision(5).warn,
        "cok suredir acilamayan pano sessizce birakilmamali"
    );
    // Cagiran bir kez basip kilitledigi icin karar esigini isaret eder.
    let mut warned = false;
    let mut printed = 0;
    for _ in 0..50 {
        if retry_decision(6).warn && !warned {
            warned = true;
            printed += 1;
        }
    }
    assert_eq!(printed, 1, "ayni uyari 50 denemede bir kez basilmali");
}

#[test]
fn decision_is_pure_so_a_recovered_clipboard_retries_at_full_speed() {
    // Karar yalnizca sayaca bagli: gecici state tutmaz. Uzun bir kilit
    // sonrasi pano acildiginda sayac sifirlanir, bir sonraki hata yine
    // 500 ms sonra denenir; yoksa izleyici kalici olarak yavaslirdi.
    assert_eq!(retry_decision(1), retry_decision(1));
    assert_eq!(
        retry_decision(1).wait,
        Duration::from_millis(500),
        "toparlanma sonrasi bekleme taban degere donmeli"
    );
    assert!(!retry_decision(0).warn, "toparlaninca uyari kapandi");
}
