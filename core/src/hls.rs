use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use m3u8_rs::{Key, KeyMethod, MasterPlaylist, MediaPlaylist, VariantStream};
use reqwest::{Client, Url};
use tokio_util::sync::CancellationToken;

use crate::engine::build_request;
use crate::manager::{DownloadEntry, DownloadManager};
use crate::models::{now_secs, DownloadMeta, Status};
use crate::stream::{self, Aes128Key, Segment};

/// SAMPLE-AES / bilinmeyen anahtar yontemleri cozulemez: kullaniciya
/// "indirme takildi" yerine ne oldugunu soyleyen net bir hata verilir.
const DRM_ERROR: &str = "Bu akis sifreli (DRM), indirilemiyor";

/// HLS gorevi: manifesti ceker, parcalari cozer ve indirmeyi `stream`'e devreder.
/// Dis sozlesme `engine::run` ile aynidir.
pub async fn run(mgr: Arc<DownloadManager>, entry: Arc<DownloadEntry>, cancel: CancellationToken) {
    let result = run_inner(&mgr, &entry, &cancel).await;

    // Duraklatma/silmede durum sahipligi manager'da; motor burada dokunmaz.
    if !cancel.is_cancelled() {
        let mut meta = entry.meta.lock().unwrap();
        match result {
            Ok(total) => {
                meta.status = Status::Completed;
                meta.total = total;
                meta.downloaded = total;
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
) -> Result<u64> {
    let meta = entry.meta.lock().unwrap().clone();
    let client = mgr.client();

    let manifest_url = Url::parse(&meta.url).context("Manifest adresi gecersiz")?;
    let body = fetch(&client, &meta.url, &meta).await?;

    // Master playlist varyant listesidir; once en iyi varyantin medya
    // listesi indirilir.
    let (media_url, media_body) = if is_master(&body) {
        let master = m3u8_rs::parse_master_playlist_res(&body)
            .map_err(|_| anyhow!("Master playlist ayristirilamadi"))?;
        let variant =
            select_variant(&master).ok_or_else(|| anyhow!("Playlistte oynatilabilir varyant yok"))?;
        let variant_url = resolve_uri(&manifest_url, &variant.uri)?;
        let bytes = fetch(&client, &variant_url, &meta).await?;
        (variant_url, bytes)
    } else {
        (meta.url.clone(), body)
    };

    let media = m3u8_rs::parse_media_playlist_res(&media_body)
        .map_err(|_| anyhow!("Medya playlisti ayristirilamadi"))?;
    let media_url = Url::parse(&media_url).context("Medya playlist adresi gecersiz")?;

    // Parca URL'leri manifest adresine gore cozulur, sayfa adresine gore degil.
    let plan = plan_segments(&media, &media_url)?;
    if plan.is_empty() {
        return Err(anyhow!("Manifestte indirilecek parca yok"));
    }

    // Ayni anahtar birden fazla parca icin gecerli olabilir; URI bazinda
    // bir kez cekilir.
    let mut keys: HashMap<String, Vec<u8>> = HashMap::new();
    for item in &plan {
        let Some(spec) = &item.key else { continue };
        if keys.contains_key(&spec.uri) {
            continue;
        }
        let bytes = fetch(&client, &spec.uri, &meta)
            .await
            .context("AES anahtari indirilemedi")?;
        if bytes.len() != 16 {
            return Err(anyhow!("AES anahtari 16 bayt degil"));
        }
        keys.insert(spec.uri.clone(), bytes);
    }

    let segments: Vec<Segment> = plan
        .iter()
        .map(|item| Segment {
            url: item.url.clone(),
            key: match &item.key {
                Some(spec) => keys.get(&spec.uri).map(|bytes| Aes128Key {
                    bytes: bytes.clone(),
                    iv: spec.iv.to_vec(),
                }),
                None => None,
            },
        })
        .collect();

    stream::run(mgr, entry, cancel, &segments).await
}

async fn fetch(client: &Client, url: &str, meta: &DownloadMeta) -> Result<Vec<u8>> {
    let resp = build_request(client, url, meta)
        .send()
        .await
        .with_context(|| format!("Istek gonderilemedi: {url}"))?;
    let status = resp.status();
    if !status.is_success() {
        return Err(anyhow!("Sunucu {} yanitini dondurdu", status.as_u16()));
    }
    let bytes = resp.bytes().await.context("Manifest govdesi okunamadi")?;
    Ok(bytes.to_vec())
}

/// Master playlist olup olmadigi ham metinden anlasilir; `#EXT-X-STREAM-INF`
/// medya listesinde asla gecmez.
fn is_master(body: &[u8]) -> bool {
    String::from_utf8_lossy(body).contains("#EXT-X-STREAM-INF")
}

/// En yuksek BANDWIDTH'li varyant secilir (kalite secimi kullaniciya birakilmadi).
/// I-frame listeleri tek basina oynatilamaz, bu yuzden son care tercih edilir.
pub fn select_variant(master: &MasterPlaylist) -> Option<&VariantStream> {
    master
        .variants
        .iter()
        .filter(|v| !v.is_i_frame)
        .max_by_key(|v| v.bandwidth)
        .or_else(|| master.variants.iter().max_by_key(|v| v.bandwidth))
}

/// Parca adresi manifest adresine gore cozulur; mutlak ve goreli bicimlerin
/// ikisi de dogru sonuc verir (`Url::join` mutlak adresi oldugu gibi birakir).
pub fn resolve_uri(base: &Url, uri: &str) -> Result<String> {
    let text = uri.trim();
    if text.is_empty() {
        return Err(anyhow!("Manifestte bos parca adresi"));
    }
    base.join(text)
        .map(|url| url.to_string())
        .map_err(|_| anyhow!("Parca adresi cozulemedi: {text}"))
}

/// Planlanan tek parca.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlannedSegment {
    pub url: String,
    /// AES-128 ise anahtar adresi ve IV; duz parcalarda `None`.
    pub key: Option<AesKeySpec>,
}

/// AES-128 anahtar tanimi. `uri` anahtarin indirilecegi adres, `iv` cozme IV'si.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AesKeySpec {
    pub uri: String,
    pub iv: [u8; 16],
}

/// Medya listesini indirilecek parca listesine cevirir. `#EXT-X-MAP` init
/// bolumu (varsa) basa eklenir; anahtar degisimi parca bazinda izlenir.
pub fn plan_segments(media: &MediaPlaylist, base: &Url) -> Result<Vec<PlannedSegment>> {
    let mut planned: Vec<PlannedSegment> = Vec::new();
    // Ayni init bolumu ardisik parcalarda tekrar bildirilebilir; bir kez eklenir.
    let mut last_init: Option<String> = None;
    // m3u8-rs anahtar etiketini yalnizca bir sonraki parcaya baglar; RFC'ye gore
    // ise yeni bir #EXT-X-KEY gorene kadar butun parcalar icin gecerlidir.
    // Bu yuzden son gorulen anahtar ileriye tasinir.
    let mut active_key: Option<Key> = None;

    for (offset, seg) in media.segments.iter().enumerate() {
        if let Some(tag) = &seg.key {
            active_key = Some(tag.clone());
        }

        // IV varsayilani parcanin medya sira numarasidir.
        let sequence = media.media_sequence + offset as u64;
        let key = match &active_key {
            // Anahtar adresi de manifest adresine gore cozulur.
            Some(tag) => match aes_key_for(tag, sequence)? {
                Some(spec) => Some(AesKeySpec {
                    uri: resolve_uri(base, &spec.uri)?,
                    iv: spec.iv,
                }),
                None => None,
            },
            None => None,
        };

        if let Some(map) = &seg.map {
            if map.byte_range.is_none() && last_init.as_deref() != Some(map.uri.as_str()) {
                last_init = Some(map.uri.clone());
                planned.push(PlannedSegment {
                    url: resolve_uri(base, &map.uri)?,
                    // Init bolumu de sifreliyse anahtari parca ile aynidir.
                    key: key.clone(),
                });
            }
        }

        planned.push(PlannedSegment {
            url: resolve_uri(base, &seg.uri)?,
            key,
        });
    }

    Ok(planned)
}

/// `#EXT-X-KEY` etiketini AES-128 cozme bilgisine cevirir. DRM'li yontemler
/// hata doner; gorev bu yuzden basarisiz gorunur ama uygulama cokmez.
pub fn aes_key_for(tag: &Key, sequence: u64) -> Result<Option<AesKeySpec>> {
    match tag.method {
        KeyMethod::None => Ok(None),
        KeyMethod::AES128 => {
            let uri = tag
                .uri
                .clone()
                .filter(|value| !value.trim().is_empty())
                .ok_or_else(|| anyhow!("Sifreli parca icin anahtar adresi yok"))?;
            let iv = match tag.iv.as_deref() {
                Some(raw) => parse_iv(raw)?,
                None => sequence_iv(sequence),
            };
            Ok(Some(AesKeySpec { uri, iv }))
        }
        // SAMPLE-AES ve taninmayan yontemler DRM demektir; cozmenin bir yolu yok.
        _ => Err(anyhow!(DRM_ERROR)),
    }
}

/// IV verilmemisse parcanin medya sira numarasi 16 baytlik big-endian IV olur.
fn sequence_iv(sequence: u64) -> [u8; 16] {
    let mut iv = [0u8; 16];
    iv[8..].copy_from_slice(&sequence.to_be_bytes());
    iv
}

fn parse_iv(raw: &str) -> Result<[u8; 16]> {
    let text = raw.trim();
    let text = text
        .strip_prefix("0x")
        .or_else(|| text.strip_prefix("0X"))
        .unwrap_or(text);
    let bytes = hex::decode(text).map_err(|_| anyhow!("Gecersiz IV degeri"))?;
    let iv: [u8; 16] = bytes
        .as_slice()
        .try_into()
        .map_err(|_| anyhow!("IV 16 bayt olmali"))?;
    Ok(iv)
}
