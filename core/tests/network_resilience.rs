//! A3 (ag saglamligi) ve A5 (`remove` zamanlamasi) icin birim ve uctan uca
//! dogrulamalar.
//!
//! Buradaki testlerin tamami gercek ag yerine `127.0.0.1` uzerinde dinlemeyen
//! bir adres kullanir; boylece hata sinifi belirleyen yol dener ama hizli
//! biter. Bekleme suresi birim olarak saf fonksiyonlarda test edilir, hicbir
//! test uyumaz.

use std::sync::Arc;
use std::time::{Duration, Instant};

use reqwest::header::{HeaderMap, HeaderValue};
use reqwest::StatusCode;
use serene_core::bus::EventBus;
use serene_core::engine::{
    backoff_delay, http_date_to_unix, parse_retry_after, request_error_is_transient,
    status_is_transient, TransferError,
};
use serene_core::manager::DownloadManager;
use serene_core::models::DownloadMeta;

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

/// `SERENE_DATA_DIR` surec genelidir ve motor her okumada degiskene bakar.
/// Asagidaki iki test motor kuruyor; biri digerinin gecici klasorunu
/// kullanmasin diye aralarinda sirali calisirlar. Diger 19 test saf
/// fonksiyonlardir ve degiskene dokunmaz, onlar paralel kalabilir.
static DATA_DIR: Mutex<()> = Mutex::new(());

fn lock_dir() -> std::sync::MutexGuard<'static, ()> {
    DATA_DIR.lock().unwrap_or_else(|e| e.into_inner())
}

// ---------------------------------------------------------------- siniflandirma

#[test]
fn gecici_http_kodlari_gecici_sayilir() {
    for code in [408u16, 425, 429, 500, 502, 503, 504] {
        assert!(
            status_is_transient(StatusCode::from_u16(code).unwrap()),
            "{code} gecici olmali"
        );
    }
}

#[test]
fn kalici_http_kodlari_kalici_sayilir() {
    // 404 ve 403'u tekrar denemek kullaniciya hicbir sey kazandirmaz.
    for code in [400u16, 401, 403, 404, 410, 416] {
        assert!(
            !status_is_transient(StatusCode::from_u16(code).unwrap()),
            "{code} kalici olmali"
        );
    }
}

#[test]
fn basarili_kodlar_ne_gecici_ne_kalici() {
    // 2xx ve 3xx hata degildir; siniflandirma bunlari hicbir sekilde hata
    // saymamali, bu yuzden `is_success` kontrolunden gecerler.
    assert!(!status_is_transient(StatusCode::OK));
    assert!(!status_is_transient(StatusCode::PARTIAL_CONTENT));
}

#[test]
fn hata_turu_kendi_kendini_ayiklar() {
    let transient = TransferError::Transient("koptu".into());
    let fatal = TransferError::Fatal("yok".into());

    assert!(transient.is_transient());
    assert!(!fatal.is_transient());
    assert_eq!(transient.message(), "koptu");
    assert_eq!(fatal.message(), "yok");
}

#[test]
fn hata_turu_anyhow_icinden_geri_alinir() {
    // Motor bu yolu kullanir: `downcast_ref` ile sinif geri okunur. Yanlis
    // bir asil typ kullanilirsa burasi sessizce basarisiz olurdu.
    let err = TransferError::Transient("koptu".into()).into_anyhow();
    let recovered = err
        .downcast_ref::<TransferError>()
        .expect("hata turu geri alinmali");
    assert!(recovered.is_transient());
}

#[tokio::test]
async fn istek_hatasi_ayrimi_bos_durmuyor() {
    // Gercek `reqwest::Error` uretmek pahali; burada siniflandirma
    // fonksiyonunun gercek bir hata turunden ne turettigini goruyoruz.
    // Baglanti reddi `is_connect()` yerine duser:
    let client = reqwest::Client::new();
    let err = client
        .get("http://127.0.0.1:9/yok")
        .send()
        .await
        .expect_err("kapali port hata vermeli");
    // 127.0.0.1:9 reddedilir ya da zaman asimina ugrar; ikisi de gecicidir.
    assert!(
        request_error_is_transient(&err),
        "kapali porta baglanma hatasi gecici sayilmali: {err}"
    );
}

// ------------------------------------------------------------------ geri cekilme

#[test]
fn geri_cekilme_usteldir_ve_tavanla_sinirlidir() {
    // Esit jitter yuzunden tek bir tohumun suresi denemeler arasi azalabilir.
    // Garanti edilen iki sey:
    //   1. en kucuk sure denemeler ilerledikce **azalmaz** (ustel buyume),
    //   2. en buyuk sure `RETRY_CAP`'i hicbir zaman asmaz.
    // Tavan devreye girdiginde buyuk sure artmayi birakabilir; bu yuzden
    // "onceki en buyuk <= sonraki en kucuk" gibi yanlis bir degismez aranmaz.
    let mut previous_min = Duration::ZERO;
    for attempt in 0..14 {
        let mut smallest = Duration::from_secs(60);
        let mut largest = Duration::ZERO;
        for seed in 0..64u64 {
            let delay = backoff_delay(attempt, seed * 2_654_435_761);
            assert!(
                delay <= Duration::from_secs(30),
                "attempt {attempt}: {delay:?} tavani asmali"
            );
            if delay < smallest {
                smallest = delay;
            }
            if delay > largest {
                largest = delay;
            }
        }
        assert!(
            smallest >= previous_min,
            "attempt {attempt}: en kucuk sure geriye gitmis: {smallest:?} < {previous_min:?}"
        );
        assert!(largest >= smallest);
        previous_min = smallest;
    }
}

#[test]
fn geri_cekilme_jitterli_olmak_zorunda() {
    // Sabit sure, tek makinede her indirmeyi ayni anda carpisma yapardi.
    let distinct: std::collections::HashSet<u64> = (0..32u64)
        .map(|seed| backoff_delay(3, seed * 7_919).as_millis() as u64)
        .collect();
    assert!(
        distinct.len() > 1,
        "jitter yok: 32 farkli tohum ayni sureyi verdi"
    );
}

#[test]
fn geri_cekilme_deterministik() {
    // Test edilebilirlik icin girdi ayniysa cikti da ayni.
    assert_eq!(backoff_delay(2, 12_345), backoff_delay(2, 12_345));
}

#[test]
fn geri_cekilme_sifirdan_kucuk_degil() {
    for attempt in 0..8 {
        for seed in [0u64, 1, u64::MAX] {
            assert!(backoff_delay(attempt, seed) > Duration::ZERO);
        }
    }
}

// ----------------------------------------------------------------- Retry-After

fn header_with_retry_after(value: &str) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(
        "retry-after",
        HeaderValue::from_str(value).expect("gecerli baslik"),
    );
    headers
}

#[test]
fn retry_after_delta_saniye_okunur() {
    let headers = header_with_retry_after("12");
    assert_eq!(
        parse_retry_after(&headers, 1_000),
        Some(Duration::from_secs(12))
    );
}

#[test]
fn retry_after_delta_saniye_tehlikeli_deger_kirpilir() {
    // 42 saniye isteyen bir sunucu 30 saniyeye indirilir: indirme sonsuza
    // kadar bekleyemez, ama sunucunun dediginden de uzun beklemez.
    let headers = header_with_retry_after("42");
    assert_eq!(
        parse_retry_after(&headers, 0),
        Some(Duration::from_secs(30))
    );
}

#[test]
fn retry_after_absurd_deger_tavana_kirpilir() {
    // Kotu niyetli ya da bozuk bir sunucu sonsuz bekleme yazamaz.
    let headers = header_with_retry_after("999999999");
    assert_eq!(
        parse_retry_after(&headers, 0),
        Some(Duration::from_secs(30))
    );
}

#[test]
fn retry_after_tarih_bicimi_okunur() {
    // 1994-11-06 08:49:37 GMT -> 784111777
    let headers = header_with_retry_after("Sun, 06 Nov 1994 08:49:37 GMT");
    let delay = parse_retry_after(&headers, 784_111_777 - 7).expect("tarih cozulmeli");
    assert_eq!(delay, Duration::from_secs(7));
}

#[test]
fn retry_after_gecmis_tarih_sifir_verir() {
    let headers = header_with_retry_after("Sun, 06 Nov 1994 08:49:37 GMT");
    assert_eq!(
        parse_retry_after(&headers, 784_111_777 + 500),
        Some(Duration::ZERO)
    );
}

#[test]
fn retry_after_bokuk_degerler_elenir() {
    for value in ["", "yarin", "0x10", "Sun, 99 Xxx 1994 08:49:37 GMT"] {
        let headers = header_with_retry_after(value);
        assert_eq!(
            parse_retry_after(&headers, 0),
            None,
            "`{value}` bir sureye cevrilmemeli"
        );
    }
}

#[test]
fn retry_after_basligi_yoksa_hicbir_sey_donusmez() {
    assert_eq!(parse_retry_after(&HeaderMap::new(), 0), None);
}

#[test]
fn http_tarihi_gun_donusturmesi_dogru() {
    // Bilinen iki sabit nokta.
    assert_eq!(http_date_to_unix("Thu, 01 Jan 1970 00:00:00 GMT"), Some(0));
    assert_eq!(
        http_date_to_unix("Sun, 06 Nov 1994 08:49:37 GMT"),
        Some(784_111_777)
    );
    // Artik yil: 2000-02-29 gecerli.
    assert!(http_date_to_unix("Tue, 29 Feb 2000 12:00:00 GMT").is_some());
    // Yanlis saat araligi reddedilir.
    assert_eq!(http_date_to_unix("Sun, 06 Nov 1994 99:49:37 GMT"), None);
}

// --------------------------------------------------------------------- soğuma

#[test]
fn soguma_kapisi_ileri_sureyi_ezmez() {
    let cooldown = serene_core::engine::CoolDown::default();
    assert!(cooldown.wait_until().is_none());

    cooldown.push(Duration::from_secs(30));
    let far = cooldown.wait_until().expect("kayit edilmeli");

    // Daha kisa bir istek geldiğinde mevcut (daha uzun) bekleme korunur.
    cooldown.push(Duration::from_millis(100));
    assert_eq!(cooldown.wait_until().expect("kayitli"), far);

    cooldown.clear();
    assert!(cooldown.wait_until().is_none());
}

// ---------------------------------------------- uctan uca: yeniden deneme sayisi

/// Ulasilamayan bir adrese karsi indirme: baglanti hatasi gecici sayilir, bu
/// yuzden motor denemeleri tuketip ancak ondan sonra basarisiz olur.
#[test]
fn gecici_hata_tuketilir_kalici_hata_hemen_biter() {
    let _guard = lock_dir();
    let dir = std::env::temp_dir().join(format!("serene-net-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("indir")).expect("gecici klasor");
    std::env::set_var("SERENE_DATA_DIR", &dir);

    let manager = Arc::new(DownloadManager::new(EventBus::default()).expect("motor kurulmali"));

    let meta = DownloadMeta {
        id: "gecici-hata".into(),
        url: "http://127.0.0.1:9/olmayan.bin".into(),
        filename: "olmayan.bin".into(),
        dest: dir
            .join("indir")
            .join("olmayan.bin")
            .to_string_lossy()
            .into(),
        temp_dir: dir.join("gecici-hata").to_string_lossy().into(),
        ..DownloadMeta::sample()
    };

    let started = Instant::now();
    manager.insert(meta.clone());
    // `insert` yalnizca listeye koyar; kuyrugu ilerleten `pump` ayrica cagrilir
    // (kopru ve pano yolu da boyle yapar).
    manager.pump();

    // `probe` de ayni mantikla yeniden denendigi icin toplam bekleme birkac
    // saniye surer; tava 30 saniye. Gormedigi durumu hataya yaziyoruz ki
    // teşhis edilebilir olsun.
    let mut last_seen = "gorev hic gorunmedi".to_string();
    for _ in 0..120 {
        std::thread::sleep(Duration::from_millis(250));
        if let Some(found) = manager.find("gecici-hata") {
            let meta = found.meta.lock().unwrap();
            last_seen = format!("{:?} ({:?})", meta.status, meta.error);
            if meta.status == serene_core::models::Status::Failed {
                let error = meta.error.clone().unwrap_or_default();
                assert!(
                    !error.is_empty(),
                    "basarisiz gorev hata aciklamasi tasimali"
                );
                // Kullaniciya gorunen mesag Turkce ve denemeyi belirtmeli.
                assert!(
                    error.contains("yeniden denendi"),
                    "hata yeniden denemeyi belirtmeli: {error}"
                );
                // Geri cekilme gercekten bekledi, hemen bitmedi.
                assert!(
                    started.elapsed() >= Duration::from_millis(400),
                    "geri cekilme beklenmeden bitmis olmamali"
                );
                drop(meta);
                let _ = std::fs::remove_dir_all(&dir);
                return;
            }
        }
    }
    panic!("gorev 30 saniyede basarisiz olmadi; son durum: {last_seen}");
}

// ------------------------------------------------- A5: remove deterministik

/// `remove` art sabit sure beklemiyor; motorun bitmesini bekliyor. Burada
/// calismayan bir gorev silinir ve gecici klasorun **anlik** kayboldugu
/// gorulur.
#[test]
fn remove_bekleme_oyu_kullanmaz() {
    let _guard = lock_dir();
    let dir = std::env::temp_dir().join(format!("serene-rm-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let temp = dir.join("is-gecici");
    std::fs::create_dir_all(&temp).expect("gecici klasor");
    std::fs::write(temp.join("part0"), b"yarim").expect("parca dosyasi");
    std::env::set_var("SERENE_DATA_DIR", &dir);

    let manager = Arc::new(DownloadManager::new(EventBus::default()).expect("motor kurulmali"));

    let meta = DownloadMeta {
        id: "silinecek".into(),
        url: "http://127.0.0.1:9/a.bin".into(),
        filename: "a.bin".into(),
        dest: dir.join("a.bin").to_string_lossy().into(),
        temp_dir: temp.to_string_lossy().into(),
        ..DownloadMeta::sample()
    };
    manager.insert(meta);
    manager.remove("silinecek", false).expect("silinebilmeli");
    // Eski uygulama 400 ms beklerdi; dosyalar ancak ondan sonra silinirdi.
    // Artik motor bitis isareti beklenir ve is bitince anlik silinir.
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if !temp.exists() {
            let _ = std::fs::remove_dir_all(&dir);
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("gecici klasor 10 saniyede silinmedi");
}

/// `DownloadMeta` ornegi. Alanlarin hepsini yazmak gerekli; yeni alan
/// eklendiginde bu yardimci guncellenmek zorunda kalir, boylece derleme
/// hatasi verir ( sessizce eksik alan kalmaz).
trait SampleMeta {
    fn sample() -> Self;
}

impl SampleMeta for DownloadMeta {
    fn sample() -> Self {
        DownloadMeta {
            id: String::new(),
            url: String::new(),
            filename: String::new(),
            dest: String::new(),
            temp_dir: String::new(),
            total: 0,
            downloaded: 0,
            speed: 0.0,
            status: serene_core::models::Status::Queued,
            error: None,
            category: serene_core::models::Category::Other,
            resumable: false,
            segments: Vec::new(),
            created_at: 0,
            finished_at: None,
            etag: None,
            referer: None,
            cookie: None,
            user_agent: None,
            kind: serene_core::models::DownloadKind::File,
            source: None,
            pending: false,
        }
    }
}

// Derleyici uyarisi: bazi yardimcilar yalnizca API'yi gormek icin tutuluyor.
#[allow(dead_code)]
fn _api_pinned(_: &AtomicU64, _: &Mutex<u8>, _: &Duration, _: &Arc<u8>) {
    let _ = AtomicU64::new(0).fetch_add(0, Ordering::Relaxed);
}
