use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Context, Result};
use cbc::cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit};
use futures_util::StreamExt;
use reqwest::Client;
use tokio::fs::{self, File};
use tokio::io::AsyncWriteExt;
use tokio_util::sync::CancellationToken;

use crate::engine::{
    backoff_delay, build_request, hide_dir, merge_parts, request_error_is_transient,
    status_is_transient, TransferError, MAX_ATTEMPTS,
};
use crate::manager::{DownloadEntry, DownloadManager};
use crate::models::{DownloadMeta, SegmentInfo};
use crate::runtime;

/// Akis parcalarindan biri. `key` doluysa parca AES-128-CBC ile sifrelidir.
#[derive(Clone)]
pub struct Segment {
    pub url: String,
    pub key: Option<Aes128Key>,
}

/// Cokme sonrasi yarim kalan parca dosyalari `segNNNNN.part` olarak durur;
/// tamamlananlar atomik olarak `segNNNNN` adina tasinir.
#[derive(Clone)]
pub struct Aes128Key {
    pub bytes: Vec<u8>,
    pub iv: Vec<u8>,
}

/// Akis parcalarini indirip `meta.dest`'e birlestirir; inen toplam bayti doner.
///
/// Motorla ayni ilerleme sozlesmesini kullanir: `base_bytes` onceki kosudan
/// diskte duran baytlari, `parts` ise parca basina canli sayaclari tutar.
/// Boylece arayuzdeki ilerleme cubugu akis gorevleri icin de calisir.
///
/// Duraklat/devam: tamamlanmis parca dosyalari yeniden inmez. Yarim kalan
/// parca (`.part`) bastan indirilir; parca icinde aralikli devam yok.
pub async fn run(
    mgr: &Arc<DownloadManager>,
    entry: &Arc<DownloadEntry>,
    cancel: &CancellationToken,
    segments: &[Segment],
) -> Result<u64> {
    if segments.is_empty() {
        return Err(anyhow!("Indirilecek parca yok"));
    }

    let meta_snapshot = Arc::new(entry.meta.lock().unwrap().clone());
    let temp_dir = PathBuf::from(&meta_snapshot.temp_dir);
    let dest = PathBuf::from(&meta_snapshot.dest);

    fs::create_dir_all(&temp_dir)
        .await
        .with_context(|| format!("Gecici klasor olusturulamadi: {}", temp_dir.display()))?;
    if let Some(workspace) = temp_dir.parent() {
        hide_dir(workspace);
    }

    let client = mgr.client();
    let segments = Arc::new(segments.to_vec());

    // Tamamlanmis parcalar diskten sayilir: duraklatip devam eden gorev
    // sifirdan indirmez.
    let mut base: u64 = 0;
    let mut counters: Vec<Arc<AtomicU64>> = Vec::with_capacity(segments.len());
    for index in 0..segments.len() {
        base += fs::metadata(seg_path(&temp_dir, index))
            .await
            .map(|m| m.len())
            .unwrap_or(0);
        counters.push(Arc::new(AtomicU64::new(0)));
    }

    entry.base_bytes.store(base, Ordering::Relaxed);
    *entry.parts.lock().unwrap() = counters.clone();

    {
        let mut meta = entry.meta.lock().unwrap();
        // Parca listesi motorun plani gibi doldurulur; bitince hls::run temizler.
        meta.segments = (0..segments.len() as u32)
            .map(|index| SegmentInfo {
                index,
                start: 0,
                end: u64::MAX,
                downloaded: 0,
            })
            .collect();
        // Toplam boyut ancak butun parcalar inince bilinir; arayuz bu sirada
        // "boyut bilinmiyor" gosterir (motorun akis yolundaki davranisi).
        meta.total = 0;
        meta.downloaded = base;
    }

    let child = cancel.child_token();
    let first_error: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let cursor = Arc::new(AtomicUsize::new(0));

    // Parcalar sirayla paylasilan bir imlecle dagitilir: siralama korunur,
    // indirme ise baglanti sayisi kadar paralel yurur.
    let workers = mgr.connections().clamp(1, 8).min(segments.len());
    let mut handles = Vec::with_capacity(workers);

    for _ in 0..workers {
        let client = client.clone();
        let meta = Arc::clone(&meta_snapshot);
        let temp_dir = temp_dir.clone();
        let cancel = child.clone();
        let first_error = Arc::clone(&first_error);
        let cursor = Arc::clone(&cursor);
        let segments = Arc::clone(&segments);
        let counters = counters.clone();

        handles.push(runtime::spawn(async move {
            loop {
                let index = cursor.fetch_add(1, Ordering::Relaxed);
                let Some(segment) = segments.get(index) else {
                    break;
                };

                let outcome = download_one(
                    &client,
                    &meta,
                    segment,
                    index,
                    &temp_dir,
                    &counters[index],
                    &cancel,
                )
                .await;

                if let Err(err) = &outcome {
                    let mut slot = first_error.lock().unwrap();
                    if slot.is_none() {
                        *slot = Some(format!("{err:#}"));
                    }
                    drop(slot);
                    // Kardes parcalar da dursun; bosuna indirmesinler.
                    cancel.cancel();
                    break;
                }
            }
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

    let parts: Vec<PathBuf> = (0..segments.len())
        .map(|index| seg_path(&temp_dir, index))
        .collect();
    merge_parts(&parts, &dest).await?;

    let total = fs::metadata(&dest).await.map(|m| m.len()).unwrap_or(0);
    {
        let mut meta = entry.meta.lock().unwrap();
        meta.total = total;
        meta.downloaded = total;
    }

    let _ = fs::remove_dir_all(&temp_dir).await;
    Ok(total)
}

/// Tek bir akis parcasini indirir; gecici hatalarda sinirli sayida yeniden
/// dener. Parca bastan inildigi icin (`Range` yok) her denemede canli sayac
/// sifirlanir; boylece yeniden deneme ilerlemeyi cift saymaz.
async fn download_one(
    client: &Client,
    meta: &DownloadMeta,
    segment: &Segment,
    index: usize,
    temp_dir: &Path,
    counter: &AtomicU64,
    cancel: &CancellationToken,
) -> Result<()> {
    let mut attempt: u32 = 0;
    loop {
        if cancel.is_cancelled() {
            return Err(TransferError::Fatal("iptal edildi".into()).into_anyhow());
        }

        counter.store(0, Ordering::Relaxed);

        match download_one_once(client, meta, segment, index, temp_dir, counter, cancel).await {
            Ok(()) => return Ok(()),
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

                let delay = backoff_delay(attempt, 0x5EED_0000u64 ^ index as u64);
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

/// Tek parcanin tek denemesi: varsa once sifresini cozer, sonra atomik olarak
/// adlandirir. Hatalar `TransferError` olarak cikar ki cagirici gecici mi
/// kalici mi oldugunu bilebilsin.
async fn download_one_once(
    client: &Client,
    meta: &DownloadMeta,
    segment: &Segment,
    index: usize,
    temp_dir: &Path,
    counter: &AtomicU64,
    cancel: &CancellationToken,
) -> Result<()> {
    let final_path = seg_path(temp_dir, index);
    if fs::metadata(&final_path)
        .await
        .map(|m| m.len() > 0)
        .unwrap_or(false)
    {
        return Ok(());
    }

    let part_path = partial_path(temp_dir, index);
    let _ = fs::remove_file(&part_path).await;

    let resp = match build_request(client, &segment.url, meta).send().await {
        Ok(resp) => resp,
        Err(err) => {
            let text = format!("Parca indirilemedi: {} ({err})", segment.url);
            return Err(if request_error_is_transient(&err) {
                TransferError::Transient(text).into_anyhow()
            } else {
                TransferError::Fatal(text).into_anyhow()
            });
        }
    };
    let status = resp.status();
    if !status.is_success() {
        let text = format!(
            "Sunucu {} yanitini dondurdu ({})",
            status.as_u16(),
            segment.url
        );
        return Err(if status_is_transient(status) {
            TransferError::Transient(text).into_anyhow()
        } else {
            TransferError::Fatal(text).into_anyhow()
        });
    }

    let mut sink = File::create(&part_path)
        .await
        .with_context(|| format!("Gecici parca acilamadi: {}", part_path.display()))?;
    let mut stream = resp.bytes_stream();
    let mut written: u64 = 0;

    loop {
        let next = tokio::select! {
            _ = cancel.cancelled() => {
                return Err(TransferError::Fatal("iptal edildi".into()).into_anyhow())
            }
            next = stream.next() => next,
        };
        let Some(chunk) = next else { break };
        let chunk = match chunk {
            Ok(chunk) => chunk,
            Err(err) => {
                return Err(
                    TransferError::Transient(format!("Veri akisi kesildi: {err}")).into_anyhow()
                )
            }
        };
        if let Err(err) = sink.write_all(&chunk).await {
            return Err(TransferError::Fatal(format!("Parca yazilamadi: {err}")).into_anyhow());
        }
        written += chunk.len() as u64;
        counter.fetch_add(chunk.len() as u64, Ordering::Relaxed);
    }
    if let Err(err) = sink.flush().await {
        return Err(TransferError::Fatal(format!("Parca yazilamadi: {err}")).into_anyhow());
    }
    drop(sink);

    if written == 0 {
        let _ = fs::remove_file(&part_path).await;
        return Err(
            TransferError::Transient(format!("Bos parca indi: {}", segment.url)).into_anyhow(),
        );
    }

    if let Some(key) = &segment.key {
        let encrypted = fs::read(&part_path)
            .await
            .with_context(|| format!("Parca okunamadi: {}", part_path.display()))?;
        let plain = decrypt_aes128(&encrypted, key)
            .with_context(|| format!("Parca cozulemedi: {}", segment.url))?;
        fs::write(&part_path, &plain).await?;
        // Sayac sifreli baytlari saymisti; dolgu cikinca duzelt.
        counter.fetch_sub(written.saturating_sub(plain.len() as u64), Ordering::Relaxed);
    }

    fs::rename(&part_path, &final_path)
        .await
        .with_context(|| format!("Parca adlandirilamadi: {}", final_path.display()))?;
    Ok(())
}

/// HLS AES-128: CBC kipi, PKCS7 dolgulu. Bazi CDN'ler dolgusuz gonderir;
/// dolgu gecersizse ham cozme sonucu korunur, veri kaybi olmaz.
pub fn decrypt_aes128(data: &[u8], key: &Aes128Key) -> Result<Vec<u8>> {
    if data.is_empty() || data.len() % 16 != 0 {
        return Err(anyhow!("Sifreli parca blok hizasinda degil"));
    }

    let mut padded = data.to_vec();
    let decryptor = cbc::Decryptor::<aes::Aes128>::new_from_slices(&key.bytes, &key.iv)
        .map_err(|_| anyhow!("AES anahtari veya IV gecersiz"))?;
    match decryptor.decrypt_padded_mut::<Pkcs7>(&mut padded) {
        Ok(plain) => return Ok(plain.to_vec()),
        Err(_) => {}
    }

    let mut raw = data.to_vec();
    let decryptor = cbc::Decryptor::<aes::Aes128>::new_from_slices(&key.bytes, &key.iv)
        .map_err(|_| anyhow!("AES anahtari veya IV gecersiz"))?;
    match decryptor.decrypt_padded_mut::<cbc::cipher::block_padding::NoPadding>(&mut raw) {
        Ok(plain) => Ok(plain.to_vec()),
        Err(_) => Err(anyhow!("Parca cozulemedi")),
    }
}

/// Parcalar 5 haneli numaralanir; dosya adi siralamasi indirme sirasini
/// yansitsin ki birlesme teshis edilebilir kalsin.
fn seg_path(temp_dir: &Path, index: usize) -> PathBuf {
    temp_dir.join(format!("seg{index:05}"))
}

fn partial_path(temp_dir: &Path, index: usize) -> PathBuf {
    temp_dir.join(format!("seg{index:05}.part"))
}
