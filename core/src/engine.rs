use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use futures_util::StreamExt;
use reqwest::header::{
    HeaderMap, ACCEPT_RANGES, COOKIE, CONTENT_DISPOSITION, CONTENT_LENGTH, CONTENT_RANGE, ETAG,
    IF_RANGE, RANGE, REFERER, USER_AGENT as UA_HEADER,
};
use reqwest::{Client, StatusCode};
use tokio::fs::{self, File, OpenOptions};
use tokio::io::{AsyncSeekExt, AsyncWriteExt, SeekFrom};
use tokio_util::sync::CancellationToken;

use crate::manager::{DownloadEntry, DownloadManager};
use crate::models::{now_secs, DownloadMeta, SegmentInfo, Status};
use crate::runtime;

pub const USER_AGENT: &str = "Serene/0.1 (Windows)";
/// Bir parcayi bolmeye degmeyecek minimum boyut.
const MIN_SEGMENT_BYTES: u64 = 1 << 20;
const MAX_SEGMENTS: usize = 16;

pub fn build_client() -> Result<Client> {
    Client::builder()
        .user_agent(USER_AGENT)
        .connect_timeout(Duration::from_secs(20))
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
/// Sunucu araliklari desteklemiyorsa 200 doner ve govdeyi okumadan baglanti kapatilir.
pub async fn probe(client: &Client, url: &str, meta: &DownloadMeta) -> Result<Probe> {
    let resp = build_request(client, url, meta)
        .header(RANGE, "bytes=0-0")
        .send()
        .await
        .context("Sunucuya baglanilamadi")?;

    let status = resp.status();
    let final_url = resp.url().to_string();
    let headers = resp.headers().clone();
    drop(resp);

    if !status.is_success() {
        return Err(anyhow!("Sunucu {} yanitini dondurdu", status.as_u16()));
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
        let end = if i + 1 == count { total - 1 } else { start + base - 1 };
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

/// Tek bir araligi indirir; var olan parca dosyasinin boyutundan devam eder.
async fn run_segment(
    client: &Client,
    url: &str,
    meta: &DownloadMeta,
    etag: Option<&str>,
    seg: &SegmentInfo,
    part_path: &Path,
    counter: &AtomicU64,
    cancel: &CancellationToken,
) -> Result<()> {
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

    let resp = request.send().await.context("Istek gonderilemedi")?;
    let status = resp.status();

    if !status.is_success() {
        return Err(anyhow!("Sunucu {} yanitini dondurdu", status.as_u16()));
    }
    if !unknown_end && status == StatusCode::OK {
        return Err(anyhow!("Sunucu aralik istegini yok saydi"));
    }

    let mut stream = resp.bytes_stream();
    loop {
        let next = tokio::select! {
            _ = cancel.cancelled() => return Err(anyhow!("iptal edildi")),
            next = stream.next() => next,
        };
        let Some(chunk) = next else { break };
        let chunk = chunk.context("Veri akisi kesildi")?;
        file.write_all(&chunk).await?;
        have += chunk.len() as u64;
        counter.fetch_add(chunk.len() as u64, Ordering::Relaxed);
    }
    file.flush().await?;

    if !unknown_end && have < want {
        return Err(anyhow!(
            "Baglanti erken kapandi ({}/{} bayt)",
            have,
            want
        ));
    }
    Ok(())
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

    // Diskte zaten duran parcalari sayarak ilerleme tabanini kur.
    let mut base: u64 = 0;
    let mut counters: Vec<Arc<AtomicU64>> = Vec::with_capacity(segments.len());
    for seg in &segments {
        let len = fs::metadata(part_path(&temp_dir, seg.index))
            .await
            .map(|m| m.len())
            .unwrap_or(0);
        let want = if seg.end == u64::MAX {
            u64::MAX
        } else {
            seg.end - seg.start + 1
        };
        let have = len.min(want);
        base += have;
        counters.push(Arc::new(AtomicU64::new(0)));
    }

    entry.base_bytes.store(base, Ordering::Relaxed);
    *entry.parts.lock().unwrap() = counters.clone();

    {
        let mut meta = entry.meta.lock().unwrap();
        meta.downloaded = base;
    }

    let child = cancel.child_token();
    let first_error: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

    let mut handles = Vec::with_capacity(segments.len());
    for (seg, counter) in segments.iter().cloned().zip(counters.iter().cloned()) {
        let client = client.clone();
        let url = url.clone();
        let meta = Arc::clone(&meta_snapshot);
        let etag = etag.clone();
        let path = part_path(&temp_dir, seg.index);
        let cancel = child.clone();
        let first_error = Arc::clone(&first_error);

        handles.push(runtime::spawn(async move {
            let outcome =
                run_segment(&client, &url, &meta, etag.as_deref(), &seg, &path, &counter, &cancel)
                    .await;
            if let Err(err) = &outcome {
                let mut slot = first_error.lock().unwrap();
                if slot.is_none() {
                    *slot = Some(format!("{err:#}"));
                }
                drop(slot);
                // Kardes parcalari da durdur, bosa indirmeyi surdurmesinler.
                cancel.cancel();
            }
            outcome
        }));
    }

    for handle in handles {
        let _ = handle.await;
    }

    if cancel.is_cancelled() {
        return Err(anyhow!("iptal edildi"));
    }
    if let Some(message) = first_error.lock().unwrap().take() {
        return Err(anyhow!(message));
    }

    // Tum parcalar tamam: birlestir ve gecici klasoru temizle.
    let parts: Vec<PathBuf> = segments.iter().map(|s| part_path(&temp_dir, s.index)).collect();
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
            if matches!(c, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') || (c as u32) < 0x20
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
    let last = parsed.path_segments()?.filter(|s| !s.is_empty()).next_back()?;
    let decoded = percent_encoding::percent_decode_str(last)
        .decode_utf8_lossy()
        .to_string();
    sanitize_filename(&decoded)
}
