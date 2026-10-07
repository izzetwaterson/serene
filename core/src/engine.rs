use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use futures_util::StreamExt;
use reqwest::header::{
    HeaderMap, ACCEPT_RANGES, CONTENT_DISPOSITION, CONTENT_LENGTH, CONTENT_RANGE, COOKIE, ETAG,
    IF_RANGE, RANGE, REFERER, USER_AGENT as UA_HEADER,
};
use reqwest::{Client, StatusCode};
use tokio::fs::{self, File, OpenOptions};
use tokio::io::{AsyncSeekExt, AsyncWriteExt, SeekFrom};
use tokio::task::{Id, JoinSet};
use tokio_util::sync::CancellationToken;

use crate::manager::{DownloadEntry, DownloadManager};
use crate::models::{now_secs, DownloadMeta, SegmentInfo, Status};

pub const USER_AGENT: &str = "Serene/0.1 (Windows)";
/// Bir parcayi bolmeye degmeyecek minimum boyut.
const MIN_SEGMENT_BYTES: u64 = 1 << 20;
const MAX_SEGMENTS: usize = 16;

/// Parca hizlarinin yeniden olculdugu aralik.
const SUPERVISE_MS: u64 = 400;
/// Bir parca, kardeslerinin ortalama hizinin bu oranindan yavas kalirsa
/// bolunmeye deger sayilir.
const SPLIT_FACTOR: f64 = 0.35;
/// Hic bayt gelmeden bu sure gecerse parca tikali sayilir.
const STALL_MS: u64 = 3000;

/// Gecici bir hata icin ilk bekleme. Sonraki denemeler bunu ikiye katlar.
const RETRY_BASE: Duration = Duration::from_millis(500);
/// Bekleme bu tavanda kesilir; kullanici sonsuza kadar beklemez.
const RETRY_CAP: Duration = Duration::from_secs(30);
/// Bir istek icin en fazla deneme sayisi (ilk deneme dahil).
///
/// Dort deneme + `CONNECT_TIMEOUT` ve ustel geri cekilme, en kotu durumda
/// ~18 saniyede "bu adrese ulasilamiyor" sonucunu verir. Besinci deneme iki
/// saniye daha ekler ama kullaniciya gorunur bir faydasi yok: ayni sunucu
/// ikinci kez de kabul etmiyorsa ucuncu de etmez.
pub const MAX_ATTEMPTS: u32 = 4;
/// Bir **baglanti** denemesinin tavani. `reqwest`in `connect_timeout`u 20
/// saniye ve `is_connect()` hatasi gecici sayildigi icin, oldugu gibi birakilsa
/// kapali bir adrese 5 x 20 = 100 saniyeye varan bir bekleme cikiyordu.
/// Indirmenin "bu adres yok" dedigini bir saniyenin biraz altinda bildirmek
/// dogru davranis: kullanici iki dakika boyunca donmus bir arayuzle kalmamali.
/// Icerik okuma (429, 503, erken kapanan govde) bu tavanda degildir; yalnizca
/// **baglanti kurma** hizlidir.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

/// Bir aktarimin neden basarisiz oldugunu ayirt eder.
///
/// `Transient` yeniden denemeye deger: baglanti koptu, zaman asimi, sunucu
/// gecici olarak bos geldi. `Fatal` yeniden denemekle duzelmez: adres yanlis,
/// yetki yok, yapı desteklenmiyor. Kullanici "Yeniden Dene" dediginde elde
/// edecegi sonuc bu ayrimla belli olur.
#[derive(Debug, Clone)]
pub enum TransferError {
    Transient(String),
    Fatal(String),
}

impl TransferError {
    pub fn message(&self) -> &str {
        match self {
            TransferError::Transient(m) | TransferError::Fatal(m) => m,
        }
    }

    pub fn is_transient(&self) -> bool {
        matches!(self, TransferError::Transient(_))
    }
}

impl std::fmt::Display for TransferError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for TransferError {}

impl TransferError {
    /// `anyhow` yigininda bu turu geri almak icin: `downcast_ref::<TransferError>()`.
    pub fn into_anyhow(self) -> anyhow::Error {
        anyhow::Error::new(self)
    }
}

/// HTTP durum kodunu gecici mi kalici mi sayar.
///
/// 408/425/429 gecici sinifta: sunucu ya da ara katman gecici olarak
/// basarisiz oldugunu bildiriyor. 401/403 kalicidir; kullanici baska bir
/// kimlikle girmiyorsa tekrar denemek anlamsiz.
pub fn status_is_transient(status: StatusCode) -> bool {
    matches!(status.as_u16(), 408 | 425 | 429 | 500 | 502 | 503 | 504)
}

/// `reqwest` hatasini siniflandirir. Baglaga donus hatalari (kopma, red,
/// zaman asimi, DNS) gecicidir; govde/ cozumleme hatalari da kismen gecicidir
/// cunku cevrimdisi bir baglanti ortada kesilmis olabilir.
pub fn request_error_is_transient(err: &reqwest::Error) -> bool {
    err.is_timeout() || err.is_connect() || err.is_request() || err.is_body() || err.is_decode()
}

/// Geri cekilme gecikmesi: ustel, `RETRY_CAP` ile sinirli, esit jitter'li.
///
/// Jitter tesadüfî olsaydı test kırılgan olurdu; bu yüzden `seed` parametrik
/// verilir. Üretimde parça numarası ve deneme sayısından türetilir, testte
/// sabit bir tohum kullanılır.
///
/// Jitter **esit** (equal jitter), tam jitter değil: gecikme daima
/// `[span/2, span]` aralığındadır. Tam jitter sıfıra düşebilir ve sıfır
/// bekleme "yeniden deneme" degil, sunucuya ayni anda tekrar tekrar gitmek
/// demektir; bu da 429 firtinasini besler.
///
/// `attempt` 0 tabanlıdır: ilk başarısızlıkta `attempt == 0` ve gecikme
/// `RETRY_BASE` içinde kalır.
pub fn backoff_delay(attempt: u32, seed: u64) -> Duration {
    let shift = attempt.min(20);
    let span =
        ((RETRY_BASE.saturating_mul(1u32 << shift).min(RETRY_CAP)).as_millis() as u64).max(2);
    let half = span / 2;
    // xorshift64*: tohum verildiginde deterministik, tohum degistiginde dagilmis.
    let mut x = seed ^ 0x9E37_79B9_7F4A_7C15;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    let noise = x.wrapping_mul(0x2545_F491_4F6C_DD1D) >> 33;
    Duration::from_millis(half + (half * noise / (1u64 << 31)))
}

/// `Retry-After` basligini sureye cevirir.
///
/// Iki bicim de RFC 7231'de tanimlidir: delta-saniye ve HTTP-tarih. Sunucu
/// absurd deger yazabilir; sonuc `RETRY_CAP` ile sinirlanir, boylece hicbir
/// indirme kasten sonsuza kadar bekleyemez.
pub fn parse_retry_after(headers: &HeaderMap, now_unix: i64) -> Option<Duration> {
    let raw = headers
        .get("retry-after")?
        .to_str()
        .ok()?
        .trim()
        .to_string();

    if let Ok(seconds) = raw.parse::<u64>() {
        return Some(Duration::from_secs(seconds).min(RETRY_CAP));
    }

    let target = http_date_to_unix(&raw)?;
    if target <= now_unix {
        return Some(Duration::ZERO);
    }
    Some(Duration::from_secs((target - now_unix) as u64).min(RETRY_CAP))
}

/// RFC 7231 `IMF-fixdate` bicimini Unix saniyeye cevirir.
///
/// Bicim sabit genisliktedir: `Sun, 06 Nov 1994 08:49:37 GMT`. Tarih kitapligi
/// eklemeden cozmek icin gun sayisi hesabi elle yapilir (Howard Hinnant'in
/// `days_from_civ` algoritmasi).
pub fn http_date_to_unix(raw: &str) -> Option<i64> {
    let raw = raw.trim();
    let rest = raw.split_once(", ")?.1;
    let mut parts = rest.split(' ');
    let day: u32 = parts.next()?.parse().ok()?;
    let month = match parts.next()? {
        "Jan" => 1,
        "Feb" => 2,
        "Mar" => 3,
        "Apr" => 4,
        "May" => 5,
        "Jun" => 6,
        "Jul" => 7,
        "Aug" => 8,
        "Sep" => 9,
        "Oct" => 10,
        "Nov" => 11,
        "Dec" => 12,
        _ => return None,
    };
    let year: i64 = parts.next()?.parse().ok()?;
    let time = parts.next()?;
    let zone = parts.next().unwrap_or("GMT");
    if zone != "GMT" {
        return None;
    }
    let mut clock = time.split(':');
    let hour: i64 = clock.next()?.parse().ok()?;
    let minute: i64 = clock.next()?.parse().ok()?;
    let second: i64 = clock.next()?.parse().ok()?;

    if !(1..=31).contains(&day) || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    Some(days_from_civil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second)
}

/// Gregory takviminda bir tarihin 1970-01-01'den gun farkini verir.
fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let m = month as i64;
    let d = day as i64;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

pub fn build_client() -> Result<Client> {
    Client::builder()
        .user_agent(USER_AGENT)
        .connect_timeout(CONNECT_TIMEOUT)
        .redirect(reqwest::redirect::Policy::limited(10))
        .build()
        .context("HTTP istemcisi olusturulamadi")
}

/// Gorev meta'sindaki istek basliklarini uygular. Referer/Cookie dogrulayan
/// CDN'ler icin sart; UA verilmemisse varsayilana duser. Istemcinin varsayilan
/// UA'si yalnizca bu yoldan gecmeyen istekler icin gecerli.
pub fn build_request(client: &Client, url: &str, meta: &DownloadMeta) -> reqwest::RequestBuilder {
    let mut request = client.get(url);
    if let Some(value) = meta.referer.as_deref() {
        request = request.header(REFERER, value);
    }
    if let Some(value) = meta.cookie.as_deref() {
        request = request.header(COOKIE, value);
    }
    request.header(UA_HEADER, meta.user_agent.as_deref().unwrap_or(USER_AGENT))
}

/// Indirmeye baslamadan once sunucudan ogrenilenler.
pub struct Probe {
    pub total: u64,
    pub resumable: bool,
    pub filename: Option<String>,
    pub etag: Option<String>,
    pub final_url: String,
}

/// `Range: bytes=0-0` ile tek baytlik bir istek atip boyut / aralik destegini ogrenir.
///
/// Bu ilk istek de gecici hataya acik: aksi halde kabloda tek bir blip tum
/// gorevi daha hicbir parca inmeden oldururdu. Ayni sinirli yeniden deneme
/// mantigi burada da gecerlidir.
pub async fn probe(client: &Client, url: &str, meta: &DownloadMeta) -> Result<Probe> {
    let mut attempt: u32 = 0;
    loop {
        let result = probe_once(client, url, meta).await;
        match result {
            Ok(probe) => return Ok(probe),
            Err(err) => {
                let transient = matches!(
                    err.downcast_ref::<TransferError>(),
                    Some(TransferError::Transient(_))
                );
                if !transient || attempt + 1 >= MAX_ATTEMPTS {
                    if attempt > 0 {
                        return Err(TransferError::Fatal(format!(
                            "{} kez yeniden denendi, son deneme basarisiz: {}",
                            attempt + 1,
                            err
                        ))
                        .into_anyhow());
                    }
                    return Err(err);
                }
                let seed = 0x5EED_0000u64 ^ u64::from(attempt);
                tokio::time::sleep(backoff_delay(attempt, seed)).await;
                attempt += 1;
            }
        }
    }
}
/// Sunucu araliklari desteklemiyorsa 200 doner ve govdeyi okumadan baglanti kapatilir.
/// `probe`'un tek denemesi. Yeniden deneme dongusu `probe` icindedir.
async fn probe_once(client: &Client, url: &str, meta: &DownloadMeta) -> Result<Probe> {
    let resp = match build_request(client, url, meta)
        .header(RANGE, "bytes=0-0")
        .send()
        .await
    {
        Ok(resp) => resp,
        Err(err) => {
            let text = format!("Sunucuya baglanilamadi: {err}");
            return Err(if request_error_is_transient(&err) {
                TransferError::Transient(text).into_anyhow()
            } else {
                TransferError::Fatal(text).into_anyhow()
            });
        }
    };

    let status = resp.status();
    let final_url = resp.url().to_string();
    let headers = resp.headers().clone();
    drop(resp);

    if !status.is_success() {
        let text = format!("Sunucu {} yanitini dondurdu", status.as_u16());
        return Err(if status_is_transient(status) {
            TransferError::Transient(text).into_anyhow()
        } else {
            TransferError::Fatal(text).into_anyhow()
        });
    }

    let filename = parse_content_disposition(&headers);
    let etag = header_str(&headers, ETAG);

    if status == StatusCode::PARTIAL_CONTENT {
        let total = parse_content_range_total(&headers).unwrap_or(0);
        return Ok(Probe {
            resumable: total > 0,
            total,
            filename,
            etag,
            final_url,
        });
    }

    let total = header_str(&headers, CONTENT_LENGTH)
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(0);
    let accept_ranges = header_str(&headers, ACCEPT_RANGES)
        .map(|v| v.eq_ignore_ascii_case("bytes"))
        .unwrap_or(false);

    Ok(Probe {
        resumable: accept_ranges && total > 0,
        total,
        filename,
        etag,
        final_url,
    })
}

/// Toplam boyutu bilinen bir dosyayi esit araliklara boler.
pub fn plan_segments(total: u64, requested: usize) -> Vec<SegmentInfo> {
    if total == 0 {
        return vec![SegmentInfo {
            index: 0,
            start: 0,
            end: u64::MAX,
            downloaded: 0,
        }];
    }

    let fit_by_size = (total / MIN_SEGMENT_BYTES).max(1) as usize;
    let count = requested.clamp(1, MAX_SEGMENTS).min(fit_by_size).max(1);
    let base = total / count as u64;

    let mut segments = Vec::with_capacity(count);
    let mut start = 0u64;
    for i in 0..count {
        let end = if i + 1 == count {
            total - 1
        } else {
            start + base - 1
        };
        segments.push(SegmentInfo {
            index: i as u32,
            start,
            end,
            downloaded: 0,
        });
        start = end + 1;
    }
    segments
}

/// Bir parca bolunmeli mi? Bolunurse yeni parcanin baslangic baytini doner.
///
/// Yalnizca anlamli bir kalan varken (>= `MIN_SEGMENT_BYTES`) ve parca ya
/// kardeslerinin ortalamasinin belirgin altinda kalirsa ya da hic
/// ilerlemezse bolunur. Tek akis (`end == u64::MAX`) bolunemez; tavan
/// `MAX_SEGMENTS`tur ve henuz hic bayt almamis parca bolunmez.
pub fn split_point(
    seg: &SegmentInfo,
    have: u64,
    rate: f64,
    peer_rate: f64,
    parts: usize,
    idle_ms: u64,
) -> Option<u64> {
    if seg.end == u64::MAX || parts >= MAX_SEGMENTS || have == 0 {
        return None;
    }
    let consumed = seg.start.checked_add(have)?;
    if consumed > seg.end {
        return None;
    }
    let remaining = seg.end - consumed + 1;
    if remaining < MIN_SEGMENT_BYTES {
        return None;
    }
    let slow = peer_rate > 0.0 && rate < peer_rate * SPLIT_FACTOR;
    let stalled = rate <= 0.0 && idle_ms >= STALL_MS;
    if !slow && !stalled {
        return None;
    }
    Some(consumed + remaining / 2)
}

/// Tek bir araligi indirir; var olan parca dosyasinin boyutundan devam eder.
/// Bir goreve ait hiz sinyali. 429 dondugunde butun parcaklar bir araya
/// gelip bekleme zamanini paylasir; boylece sunucu reddederken biz de
/// tekrar tekrar istek atip durmaziz. Kullanici `connections` ayarini elle
/// dusurmek zorunda kalmaz.
#[derive(Default)]
pub struct CoolDown {
    until: Mutex<Option<Instant>>,
}

impl CoolDown {
    /// Hangi saate kadar beklenmeli. `Instant` tabanli oldugu icin saat
    /// degisimi (NTP, yaz saati) beklemeyi bozmaz.
    pub fn wait_until(&self) -> Option<Instant> {
        *self.until.lock().unwrap()
    }

    /// Yeni bir bekleme kaydeder; daha gecis bir bekleme varsa onu ezmez.
    pub fn push(&self, delay: Duration) {
        let target = Instant::now() + delay;
        let mut slot = self.until.lock().unwrap();
        if slot.map(|current| current < target).unwrap_or(true) {
            *slot = Some(target);
        }
    }

    pub fn clear(&self) {
        *self.until.lock().unwrap() = None;
    }
}

/// Bir parcayı indirmek için gereken her şey. Argüman listesini taşımak yerine
/// tek bir kayıt taşınır: `run_segment` ve `run_segment_once` aynı paketi kullanır.
pub(crate) struct SegmentJob<'a> {
    client: &'a Client,
    url: &'a str,
    meta: &'a DownloadMeta,
    etag: Option<&'a str>,
    seg: &'a SegmentInfo,
    part_path: &'a Path,
    counter: &'a AtomicU64,
    cancel: &'a CancellationToken,
    cooldown: &'a CoolDown,
}

/// `run_segment` icin tek bir deneme. Hata turu `TransferError` olarak cikar,
/// cunku cagirici (ve test) gecici mi kalici mi oldugunu bilmelidir.
async fn run_segment_once(job: &SegmentJob<'_>) -> Result<()> {
    let SegmentJob {
        client,
        url,
        meta,
        etag,
        seg,
        part_path,
        counter,
        cancel,
        ..
    } = *job;
    let (client, url, meta, etag, seg, part_path, counter, cancel) =
        (client, url, meta, etag, seg, part_path, counter, cancel);
    let cooldown = job.cooldown;

    let unknown_end = seg.end == u64::MAX;
    let want = if unknown_end {
        u64::MAX
    } else {
        seg.end - seg.start + 1
    };

    let mut file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(part_path)
        .await
        .with_context(|| format!("Gecici dosya acilamadi: {}", part_path.display()))?;

    let existing = file.metadata().await?.len();
    let mut have = existing.min(want);
    if !unknown_end && have >= want {
        return Ok(());
    }

    // Sunucu aralik desteklemiyorsa (`unknown_end`) devam edilemez: `Range`
    // gonderilemedigi icin sunucu govdeyi bastan yollar. Yarim kalan parcanin
    // uzerine eklemek dosyayi bozar; bu yuzden bastan indirilir.
    if unknown_end {
        have = 0;
    }

    // Yarim kalmis kuyrugu at, dogru offsetten devam et.
    file.set_len(have).await?;
    file.seek(SeekFrom::Start(have)).await?;

    let mut request = build_request(client, url, meta);
    if !unknown_end {
        request = request.header(RANGE, format!("bytes={}-{}", seg.start + have, seg.end));
    }
    if have > 0 {
        if let Some(tag) = etag {
            request = request.header(IF_RANGE, tag);
        }
    }

    let resp = match request.send().await {
        Ok(resp) => resp,
        Err(err) => {
            let text = format!("Istek gonderilemedi: {err}");
            return Err(if request_error_is_transient(&err) {
                TransferError::Transient(text).into_anyhow()
            } else {
                TransferError::Fatal(text).into_anyhow()
            });
        }
    };
    let status = resp.status();

    if !status.is_success() {
        // Sunucu ne kadar beklememizi istiyorsa onu gireriz. 429'da bu genelde
        // tek gondermede gelir ve butun parcalarin kapida toplanmasini saglar.
        if let Some(delay) = parse_retry_after(resp.headers(), now_secs()) {
            if !delay.is_zero() {
                cooldown.push(delay);
            }
        }
        let text = format!("Sunucu {} yanitini dondurdu", status.as_u16());
        return Err(if status_is_transient(status) {
            TransferError::Transient(text).into_anyhow()
        } else {
            TransferError::Fatal(text).into_anyhow()
        });
    }
    if !unknown_end && status == StatusCode::OK {
        return Err(TransferError::Fatal("Sunucu aralik istegini yok saydi".into()).into_anyhow());
    }

    let mut stream = resp.bytes_stream();
    loop {
        let next = tokio::select! {
            _ = cancel.cancelled() => return Err(TransferError::Fatal("iptal edildi".into()).into_anyhow()),
            next = stream.next() => next,
        };
        let Some(chunk) = next else { break };
        let chunk = match chunk {
            Ok(chunk) => chunk,
            Err(err) => {
                // Baglanti ortada koptu: dosya uzerinde kalan baytlar durur,
                // bir sonraki deneme `If-Range` ile kaldigi yerden devam eder.
                let text = format!("Veri akisi kesildi: {err}");
                return Err(TransferError::Transient(text).into_anyhow());
            }
        };
        if let Err(err) = file.write_all(&chunk).await {
            // Disk hatasi kalicidir; yeniden denemek dosyayi kurtarmaz.
            return Err(TransferError::Fatal(format!("Parca yazilamadi: {err}")).into_anyhow());
        }
        have += chunk.len() as u64;
        counter.fetch_add(chunk.len() as u64, Ordering::Relaxed);
    }
    file.flush().await?;

    if !unknown_end && have < want {
        // Sunucu erken kapatti: gecici sayilir, devam edilebilir.
        return Err(TransferError::Transient(format!(
            "Baglanti erken kapandi ({}/{} bayt)",
            have, want
        ))
        .into_anyhow());
    }
    Ok(())
}

/// Bir parcayi indirir; gecici hatalarda sinirli sayida yeniden dener.
///
/// Yeniden deneme yalnizca `Transient` hatalarda olur. Her deneme diskteki
/// mevcut baytlari devralir, yani kullanici gormese bile ilerleme kaybolmaz.
/// Kalici hata ilk denemede gorevi bitirir.
pub(crate) async fn run_segment(job: SegmentJob<'_>) -> Result<()> {
    let cancel = job.cancel;
    let cooldown = job.cooldown;
    let seg = job.seg;
    let mut attempt: u32 = 0;
    loop {
        if cancel.is_cancelled() {
            return Err(TransferError::Fatal("iptal edildi".into()).into_anyhow());
        }

        // 429 sonrasi butun parcalar ayni kapida bekler.
        if let Some(until) = cooldown.wait_until() {
            let now = Instant::now();
            if until > now {
                tokio::select! {
                    _ = cancel.cancelled() => {
                        return Err(TransferError::Fatal("iptal edildi".into()).into_anyhow())
                    }
                    _ = tokio::time::sleep_until(until.into()) => {}
                }
            }
        }

        let outcome = run_segment_once(&job).await;

        match outcome {
            Ok(()) => {
                cooldown.clear();
                return Ok(());
            }
            Err(err) => {
                let transient = match err.downcast_ref::<TransferError>() {
                    Some(TransferError::Transient(_)) => true,
                    // `Fatal` icinde iptal de vardir; her iki durumda da
                    // yeniden denemek yanlis.
                    Some(TransferError::Fatal(_)) => false,
                    // Bizim katmanimizdan gelmeyen hata: dosya acma, aralik
                    // hesabi gibi. Yeniden denemek zararsiz ama anlamli degil.
                    None => false,
                };

                if !transient || attempt + 1 >= MAX_ATTEMPTS {
                    if attempt > 0 {
                        return Err(TransferError::Fatal(format!(
                            "{} kez yeniden denendi, son deneme basarisiz: {}",
                            attempt + 1,
                            err
                        ))
                        .into_anyhow());
                    }
                    return Err(err);
                }

                // Sunucu `Retry-After` verdiyse onu esas al; yoksa jitter'li
                // ustel geri cekilme.
                let delay = match cooldown.wait_until() {
                    Some(until) => until
                        .saturating_duration_since(Instant::now())
                        .max(backoff_delay(attempt, seed_for(seg.index, attempt))),
                    None => backoff_delay(attempt, seed_for(seg.index, attempt)),
                };

                attempt += 1;
                tokio::select! {
                    _ = cancel.cancelled() => {
                        return Err(TransferError::Fatal("iptal edildi".into()).into_anyhow())
                    }
                    _ = tokio::time::sleep(delay) => {}
                }
            }
        }
    }
}

/// Parca ve denemeden turetilen tohum. Ayni parca ayni denemede ayni jitter'i
/// alir; testler bunu deterministik bulmak icin kullanir.
fn seed_for(index: u32, attempt: u32) -> u64 {
    (u64::from(index) << 32) ^ u64::from(attempt).wrapping_mul(0x9E37_79B9_7F4A_7C15)
}

/// Parca dosyalarini sirayla nihai dosyaya birlestirir, sonra nihai adi verir.
/// Akis indiricileri de ayni son sozlesmeyi kullanir (staging + atomik rename).
pub(crate) async fn merge_parts(parts: &[PathBuf], dest: &Path) -> Result<()> {
    let staging = PathBuf::from(format!("{}.serene-merge", dest.display()));
    {
        let mut out = File::create(&staging)
            .await
            .with_context(|| format!("Hedef dosya olusturulamadi: {}", staging.display()))?;
        for part in parts {
            let mut src = File::open(part)
                .await
                .with_context(|| format!("Parca okunamadi: {}", part.display()))?;
            tokio::io::copy(&mut src, &mut out).await?;
        }
        out.flush().await?;
        out.sync_all().await.ok();
    }

    if dest.exists() {
        let _ = fs::remove_file(dest).await;
    }
    fs::rename(&staging, dest)
        .await
        .with_context(|| format!("Dosya tasinamadi: {}", dest.display()))?;
    Ok(())
}

fn part_path(temp_dir: &Path, index: u32) -> PathBuf {
    temp_dir.join(format!("part{index}"))
}

/// Gecici parca klasoru indirme klasorunun icinde durur; boylece birlestirme
/// ayni birim uzerinde kalir ve anlik `rename` ile biter. Kullaniciyi
/// rahatsiz etmemesi icin gizli isaretlenir.
#[cfg(windows)]
pub(crate) fn hide_dir(path: &Path) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    let _ = std::process::Command::new("attrib")
        .arg("+h")
        .arg(path.as_os_str())
        .creation_flags(CREATE_NO_WINDOW)
        .status();
}

#[cfg(not(windows))]
pub(crate) fn hide_dir(_path: &Path) {}

/// Bir gorevi bastan (veya kaldigi yerden) indirir.
pub async fn run(mgr: Arc<DownloadManager>, entry: Arc<DownloadEntry>, cancel: CancellationToken) {
    let result = run_inner(&mgr, &entry, &cancel).await;

    // Kullanici duraklattiysa / gorevi sildiyse durum sahipligi manager'da;
    // motor burada duruma dokunmaz.
    if !cancel.is_cancelled() {
        let mut meta = entry.meta.lock().unwrap();
        match result {
            Ok(()) => {
                meta.status = Status::Completed;
                meta.downloaded = meta.total.max(meta.downloaded);
                meta.speed = 0.0;
                meta.error = None;
                meta.finished_at = Some(now_secs());
                meta.segments.clear();
            }
            Err(err) => {
                meta.status = Status::Failed;
                meta.speed = 0.0;
                meta.error = Some(format!("{err:#}"));
            }
        }
    }

    mgr.on_task_stopped(&entry.id);
}

async fn run_inner(
    mgr: &Arc<DownloadManager>,
    entry: &Arc<DownloadEntry>,
    cancel: &CancellationToken,
) -> Result<()> {
    // Basliklar da meta'dan tasinir; parca gorevleri arka planda kostugu icin
    // tam meta tek nushada paylasilir.
    let meta_snapshot = Arc::new(entry.meta.lock().unwrap().clone());
    let url = meta_snapshot.url.clone();
    let temp_dir = PathBuf::from(&meta_snapshot.temp_dir);
    let dest = PathBuf::from(&meta_snapshot.dest);
    let etag = meta_snapshot.etag.clone();
    let segments = meta_snapshot.segments.clone();

    fs::create_dir_all(&temp_dir)
        .await
        .with_context(|| format!("Gecici klasor olusturulamadi: {}", temp_dir.display()))?;

    if let Some(workspace) = temp_dir.parent() {
        hide_dir(workspace);
    }

    let client = mgr.client();

    // Boyut/aralik bilgisi yoksa (ilk denemede alinamadiysa) tekrar sor.
    let segments = if segments.is_empty() {
        let probe = probe(&client, &url, &meta_snapshot).await?;
        let planned = if probe.resumable {
            plan_segments(probe.total, mgr.connections())
        } else {
            plan_segments(0, 1)
        };
        let mut meta = entry.meta.lock().unwrap();
        meta.total = probe.total;
        meta.resumable = probe.resumable;
        meta.etag = probe.etag.clone();
        meta.segments = planned.clone();
        drop(meta);
        planned
    } else {
        segments
    };

    // Diskte zaten duran baytlar SAYACIN kendisine tohumlanir: boylece bir
    // parcanin sayaci her zaman "bu parca icin inen toplam bayt" olur ve
    // ilerleme tabani ayri bir skalere ihtiyac duymaz. Duraklat/devam sonrasi
    // parca basina ilerleme sifirlanmaz ve bolme karari dogru `have` okur.
    let mut downloaded: u64 = 0;
    let mut counters: Vec<Arc<AtomicU64>> = Vec::with_capacity(segments.len());
    for seg in &segments {
        let len = fs::metadata(part_path(&temp_dir, seg.index))
            .await
            .map(|m| m.len())
            .unwrap_or(0);
        // Tek akis (`unknown_end`) devam edemez: dosya bastan iner, tohum yok.
        let have = if seg.end == u64::MAX {
            0
        } else {
            len.min(seg.end - seg.start + 1)
        };
        downloaded += have;
        counters.push(Arc::new(AtomicU64::new(have)));
    }

    entry.base_bytes.store(0, Ordering::Relaxed);
    *entry.parts.lock().unwrap() = counters.clone();

    {
        let mut meta = entry.meta.lock().unwrap();
        meta.downloaded = downloaded;
    }

    let child = cancel.child_token();
    let first_error: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    // 429 gorulurse butun parcalar bu kapida bekler.
    let cooldown = Arc::new(CoolDown::default());

    let ctx = PartCtx {
        client: client.clone(),
        url: url.clone(),
        meta: Arc::clone(&meta_snapshot),
        temp_dir: temp_dir.clone(),
        etag: etag.clone(),
        child: child.clone(),
        first_error: Arc::clone(&first_error),
        cooldown: Arc::clone(&cooldown),
    };

    // Her parca bir is; denetleyici yavas/tikali parcalari bolup yenisini ekler.
    let mut set: JoinSet<()> = JoinSet::new();
    let mut runs: Vec<PartRun> = Vec::with_capacity(segments.len());
    let mut next_index: u32 = segments
        .iter()
        .map(|s| s.index)
        .max()
        .map_or(0, |m| m + 1);
    for (seg, counter) in segments.iter().cloned().zip(counters.into_iter()) {
        runs.push(spawn_part(&mut set, &ctx, seg, counter));
    }

    let mut tick = tokio::time::interval(Duration::from_millis(SUPERVISE_MS));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    tick.tick().await; // ilk tick hemen tetiklenir; atla.

    // Bolunmesi istenen parcanin isi ve bolme noktasi; bitisi beklenip uygulanir.
    let mut splitting: Option<(Id, u64)> = None;

    while !set.is_empty() {
        tokio::select! {
            _ = tick.tick() => {
                if splitting.is_none() {
                    splitting = supervise(&mut runs);
                }
            }
            joined = set.join_next_with_id() => {
                match joined {
                    Some(Ok((id, ()))) => {
                        match splitting {
                            Some((target, boundary)) if target == id => {
                                apply_split(
                                    &mut set,
                                    &mut runs,
                                    &ctx,
                                    id,
                                    boundary,
                                    &mut next_index,
                                    entry,
                                );
                                splitting = None;
                            }
                            _ => {
                                runs.retain(|run| run.id != id);
                            }
                        }
                    }
                    Some(Err(err)) => {
                        let mut slot = first_error.lock().unwrap();
                        if slot.is_none() {
                            *slot = Some(format!("parca gorevi coktu: {err}"));
                        }
                        drop(slot);
                        child.cancel();
                    }
                    None => break,
                }
            }
        }
    }

    if cancel.is_cancelled() {
        return Err(anyhow!("iptal edildi"));
    }
    if let Some(message) = first_error.lock().unwrap().take() {
        return Err(anyhow!(message));
    }

    // Tum parcalar tamam: guncel plan sirasina gore birlestir ve temizle.
    let plan = entry.meta.lock().unwrap().segments.clone();
    let parts: Vec<PathBuf> = plan
        .iter()
        .map(|s| part_path(&temp_dir, s.index))
        .collect();
    merge_parts(&parts, &dest).await?;

    let final_len = fs::metadata(&dest).await.map(|m| m.len()).unwrap_or(0);
    {
        let mut meta = entry.meta.lock().unwrap();
        if meta.total == 0 {
            meta.total = final_len;
        }
        meta.downloaded = meta.total;
    }

    let _ = fs::remove_dir_all(&temp_dir).await;
    Ok(())
}

/// Parca gorevlerinin paylastigi baglam (istek basliklari, iptal, hata).
struct PartCtx {
    client: Client,
    url: String,
    meta: Arc<DownloadMeta>,
    temp_dir: PathBuf,
    etag: Option<String>,
    child: CancellationToken,
    first_error: Arc<Mutex<Option<String>>>,
    cooldown: Arc<CoolDown>,
}

/// Denetleyicinin izledigi canli parca.
struct PartRun {
    id: Id,
    index: u32,
    start: u64,
    end: u64,
    counter: Arc<AtomicU64>,
    cancel: CancellationToken,
    last_bytes: u64,
    last_at: Instant,
    last_change: Instant,
    rate: f64,
}

/// Bir parcayi is setine ekler ve denetleyicinin izleyecegi kaydi doner.
fn spawn_part(
    set: &mut JoinSet<()>,
    ctx: &PartCtx,
    seg: SegmentInfo,
    counter: Arc<AtomicU64>,
) -> PartRun {
    let seg_cancel = ctx.child.child_token();
    let job_cancel = seg_cancel.clone();
    let child = ctx.child.clone();
    let client = ctx.client.clone();
    let url = ctx.url.clone();
    let meta = Arc::clone(&ctx.meta);
    let path = part_path(&ctx.temp_dir, seg.index);
    let etag = ctx.etag.clone();
    let first_error = Arc::clone(&ctx.first_error);
    let cooldown = Arc::clone(&ctx.cooldown);
    let job_counter = Arc::clone(&counter);
    let job_seg = seg.clone();

    let handle = set.spawn(async move {
        let outcome = run_segment(SegmentJob {
            client: &client,
            url: &url,
            meta: &meta,
            etag: etag.as_deref(),
            seg: &job_seg,
            part_path: &path,
            counter: &job_counter,
            cancel: &job_cancel,
            cooldown: &cooldown,
        })
        .await;
        if let Err(err) = &outcome {
            // Denetleyici bu parcayi bolmek icin iptal ettiyse hata degildir.
            if !job_cancel.is_cancelled() {
                let mut slot = first_error.lock().unwrap();
                if slot.is_none() {
                    *slot = Some(format!("{err:#}"));
                }
                drop(slot);
                // Kardes parcalari da durdur, bosa indirmeyi surdurmesinler.
                child.cancel();
            }
        }
    });

    let now = Instant::now();
    // Sayac tohumlu olabilir (devam eden ya da bolunup yeniden kosan parca):
    // hiz olcumu bu noktadan baslar, yoksa ilk turda sahte bir sicrama olur.
    let seeded = counter.load(Ordering::Relaxed);
    PartRun {
        id: handle.id(),
        index: seg.index,
        start: seg.start,
        end: seg.end,
        counter,
        cancel: seg_cancel,
        last_bytes: seeded,
        last_at: now,
        last_change: now,
        rate: 0.0,
    }
}

/// Parca hizlarini ornekler ve bolunmesi gereken parcayi isaretler.
///
/// Bir turda yalnizca en yavas parca secilir; boylece parca sayisi kontrollu
/// artar ve ayni anda birden fazla bolme olmaz. Donen `u64`, `split_point`in
/// hesapladigi bolme noktasidir: kurban oraya kadar iner, kalan yarisini yeni
/// baglanti alir.
fn supervise(runs: &mut [PartRun]) -> Option<(Id, u64)> {
    let now = Instant::now();
    for run in runs.iter_mut() {
        let bytes = run.counter.load(Ordering::Relaxed);
        let elapsed = now.duration_since(run.last_at).as_secs_f64();
        if bytes > run.last_bytes && elapsed > 0.0 {
            let instant = (bytes - run.last_bytes) as f64 / elapsed;
            run.rate = if run.rate > 0.0 {
                run.rate * 0.6 + instant * 0.4
            } else {
                instant
            };
            run.last_bytes = bytes;
            run.last_change = now;
        } else {
            run.rate = 0.0;
        }
        run.last_at = now;
    }

    let moving: Vec<f64> = runs
        .iter()
        .map(|run| run.rate)
        .filter(|rate| *rate > 0.0)
        .collect();
    let peer = if moving.is_empty() {
        0.0
    } else {
        moving.iter().sum::<f64>() / moving.len() as f64
    };
    let parts = runs.len();

    let mut victim: Option<(usize, f64, u64)> = None;
    for (i, run) in runs.iter().enumerate() {
        let have = run.counter.load(Ordering::Relaxed);
        let idle = now.duration_since(run.last_change).as_millis() as u64;
        let seg = SegmentInfo {
            index: run.index,
            start: run.start,
            end: run.end,
            downloaded: have,
        };
        let Some(boundary) = split_point(&seg, have, run.rate, peer, parts, idle) else {
            continue;
        };
        if victim.map_or(true, |(_, best, _)| run.rate < best) {
            victim = Some((i, run.rate, boundary));
        }
    }

    let (i, _, boundary) = victim?;
    runs[i].cancel.cancel();
    Some((runs[i].id, boundary))
}

/// Kurban parcayi ikiye ayirir: kalan yarisini yeni bir baglantiya verir.
///
/// Kurbanin isi coktan bitmis olmali (denetleyici iptal etti, `join_next` ile
/// bekledik); boylece sayaci sabittir. Kurban daraltilmis araligiyla ve ayni
/// sayacla yeniden kosar, taze parca kalan yariyi alir.
fn apply_split(
    set: &mut JoinSet<()>,
    runs: &mut Vec<PartRun>,
    ctx: &PartCtx,
    id: Id,
    boundary: u64,
    next_index: &mut u32,
    entry: &Arc<DownloadEntry>,
) {
    let Some(pos) = runs.iter().position(|run| run.id == id) else {
        return;
    };
    let run = runs.remove(pos);
    let have = run.counter.load(Ordering::Relaxed);
    let Some(consumed) = run.start.checked_add(have) else {
        return;
    };
    // Hic ilerlememis parca ya da anlamsiz bir nokta: bolme yok.
    if have == 0 || boundary <= consumed || boundary > run.end {
        return;
    }

    // Kurban `[start, boundary-1]` araligina daralir; kalan yarisini yeni
    // parca alir. Ikisi de ayni anda iner.
    let victim = SegmentInfo {
        index: run.index,
        start: run.start,
        end: boundary - 1,
        downloaded: have,
    };
    let fresh = SegmentInfo {
        index: *next_index,
        start: boundary,
        end: run.end,
        downloaded: 0,
    };
    *next_index += 1;
    let fresh_counter = Arc::new(AtomicU64::new(0));

    // Plan ve canli sayaclar konumsal hizali kalmali: ayni sirada guncelle.
    let insert_at = {
        let mut meta = entry.meta.lock().unwrap();
        if let Some(seg) = meta.segments.iter_mut().find(|s| s.index == run.index) {
            seg.end = victim.end;
            seg.downloaded = have;
        }
        let at = meta
            .segments
            .iter()
            .position(|s| s.start > fresh.start)
            .unwrap_or(meta.segments.len());
        meta.segments.insert(at, fresh.clone());
        at
    };
    {
        let mut parts = entry.parts.lock().unwrap();
        let at = insert_at.min(parts.len());
        parts.insert(at, Arc::clone(&fresh_counter));
    }

    // Kurban AYNI sayacla yeniden kosar: dosyasi `have` baytta duruyor ve
    // `Range` oradan devam eder, boylece inen bayt bosa gitmez.
    runs.push(spawn_part(set, ctx, victim, run.counter.clone()));
    runs.push(spawn_part(set, ctx, fresh, fresh_counter));
}

fn header_str(headers: &HeaderMap, name: reqwest::header::HeaderName) -> Option<String> {
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// `Content-Range: bytes 0-0/1234` -> 1234
fn parse_content_range_total(headers: &HeaderMap) -> Option<u64> {
    let raw = header_str(headers, CONTENT_RANGE)?;
    let total = raw.rsplit('/').next()?.trim();
    if total == "*" {
        return None;
    }
    total.parse::<u64>().ok()
}

/// `Content-Disposition` basligindan dosya adini cikarir (RFC 5987 dahil).
fn parse_content_disposition(headers: &HeaderMap) -> Option<String> {
    let raw = header_str(headers, CONTENT_DISPOSITION)?;

    for part in raw.split(';') {
        let part = part.trim();
        if let Some(rest) = part.strip_prefix("filename*=") {
            let rest = rest.trim().trim_matches('"');
            let encoded = rest.splitn(3, '\'').nth(2).unwrap_or(rest);
            let decoded = percent_encoding::percent_decode_str(encoded)
                .decode_utf8_lossy()
                .to_string();
            if let Some(name) = sanitize_filename(&decoded) {
                return Some(name);
            }
        }
    }

    for part in raw.split(';') {
        let part = part.trim();
        if let Some(rest) = part.strip_prefix("filename=") {
            let rest = rest.trim().trim_matches('"');
            if let Some(name) = sanitize_filename(rest) {
                return Some(name);
            }
        }
    }
    None
}

/// Ayni ada sahip bir dosya varsa " (1)", " (2)" ... ekleyerek bos isim bulur.
pub fn unique_dest(dir: &Path, filename: &str) -> PathBuf {
    let candidate = dir.join(filename);
    if !candidate.exists() {
        return candidate;
    }

    let path = Path::new(filename);
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("indirme");
    let ext = path.extension().and_then(|s| s.to_str());

    for n in 1..10_000u32 {
        let name = match ext {
            Some(ext) => format!("{stem} ({n}).{ext}"),
            None => format!("{stem} ({n})"),
        };
        let candidate = dir.join(name);
        if !candidate.exists() {
            return candidate;
        }
    }
    dir.join(filename)
}

/// Yol ayiricilarini ve Windows'ta gecersiz karakterleri temizler,
/// `..` ile dizin disina cikma denemelerini etkisiz kilar.
pub fn sanitize_filename(name: &str) -> Option<String> {
    let last = name.rsplit(['/', '\\']).next().unwrap_or(name).trim();
    if last.is_empty() || last == "." || last == ".." {
        return None;
    }

    let cleaned: String = last
        .chars()
        .map(|c| {
            if matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*')
                || (c as u32) < 0x20
            {
                '_'
            } else {
                c
            }
        })
        .collect();

    let cleaned = cleaned.trim_matches(['.', ' ']).to_string();
    if cleaned.is_empty() {
        None
    } else {
        Some(cleaned)
    }
}

/// URL yolundan dosya adi tahmini.
pub fn filename_from_url(url: &str) -> Option<String> {
    let parsed = reqwest::Url::parse(url).ok()?;
    let last = parsed
        .path_segments()?
        .filter(|s| !s.is_empty())
        .next_back()?;
    let decoded = percent_encoding::percent_decode_str(last)
        .decode_utf8_lossy()
        .to_string();
    sanitize_filename(&decoded)
}
