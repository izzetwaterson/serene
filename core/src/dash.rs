use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use quick_xml::escape::unescape;
use quick_xml::events::{BytesStart, Event};
use quick_xml::{Reader, XmlVersion};
use reqwest::{Client, Url};
use tokio_util::sync::CancellationToken;

use crate::engine::build_request;
use crate::manager::{DownloadEntry, DownloadManager};
use crate::models::{now_secs, DownloadMeta, Status};
use crate::stream::{self, Segment};

/// DASH sifrelemesi CENC ile yapilir; anahtar teslimi (PSSH/lisans) bu surumde
/// yok. "Indirme takildi" yerine ne oldugunu soyleyen net bir hata verilir.
const DRM_ERROR: &str = "Bu akis sifreli (DRM), indirilemiyor";

/// DASH gorevi: MPD'yi ceker, secilen video temsilinin parcalarini cozer ve
/// indirmeyi `stream`'e devreder. Dis sozlesme `hls::run` ile aynidir.
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

    // Parca adresleri manifest adresine gore cozulur, sayfa adresine gore degil.
    let manifest_url = Url::parse(&meta.url).context("MPD adresi gecersiz")?;
    let body = fetch(&client, &meta.url, &meta).await?;
    let text = std::str::from_utf8(&body).context("MPD metni UTF-8 degil")?;

    let urls = plan_segments(text, &manifest_url)?;
    if urls.is_empty() {
        return Err(anyhow!("Manifestte indirilecek parca yok"));
    }

    // DASH parcalari sifresiz fMP4'tur; anahtar HLS yolundaki gibi tasinmaz.
    let segments: Vec<Segment> = urls
        .into_iter()
        .map(|url| Segment { url, key: None })
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
    let bytes = resp.bytes().await.context("MPD govdesi okunamadi")?;
    Ok(bytes.to_vec())
}

/* ---------- MPD alt kumesi ---------- */

/// MPD kucuk bir XML belgesidir; gerekli alt kume icin olay tabanli bir durum
/// makinesi yerine basit bir agac kurmak daha okunur ve hataya daha kapali.
#[derive(Default)]
struct XmlNode {
    name: String,
    attrs: Vec<(String, String)>,
    text: String,
    children: Vec<XmlNode>,
}

impl XmlNode {
    fn attr(&self, name: &str) -> Option<&str> {
        self.attrs
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.as_str())
    }

    fn child(&self, name: &str) -> Option<&XmlNode> {
        self.children.iter().find(|node| node.name == name)
    }

    fn children_named(&self, name: &str) -> Vec<&XmlNode> {
        self.children
            .iter()
            .filter(|node| node.name == name)
            .collect()
    }
}

/// Ad alanli adlardan yerel adi cikarir (`ns:SegmentTemplate` -> `SegmentTemplate`).
fn local(raw: &str) -> &str {
    raw.rsplit(':').next().unwrap_or(raw)
}

fn node_of(start: &BytesStart) -> XmlNode {
    let mut node = XmlNode {
        name: local(start.name().into_inner()).to_string(),
        ..Default::default()
    };
    for attr in start.attributes().flatten() {
        let raw = attr.key.into_inner();
        // Ad alani bildirimleri icerik degil, etiketleme ayrintisidir.
        if raw.starts_with("xmlns") {
            continue;
        }
        // Cozulemeyen varliklar ham deger olarak korunur; veri kaybi olmaz.
        let value = attr
            .normalized_value(XmlVersion::Implicit1_0)
            .map(|text| text.into_owned())
            .unwrap_or_else(|_| attr.value.to_string());
        node.attrs.push((local(raw).to_string(), value));
    }
    node
}

fn parse_dom(text: &str) -> Result<XmlNode> {
    let mut reader = Reader::from_str(text);
    let mut stack: Vec<XmlNode> = vec![XmlNode::default()];

    loop {
        match reader.read_event() {
            Ok(Event::Start(start)) => stack.push(node_of(&start)),
            Ok(Event::Empty(start)) => {
                let node = node_of(&start);
                stack
                    .last_mut()
                    .ok_or_else(|| anyhow!("MPD yapisi bozuk"))?
                    .children
                    .push(node);
            }
            Ok(Event::End(_)) => {
                let done = stack.pop().ok_or_else(|| anyhow!("MPD yapisi bozuk"))?;
                stack
                    .last_mut()
                    .ok_or_else(|| anyhow!("MPD yapisi bozuk"))?
                    .children
                    .push(done);
            }
            Ok(Event::Text(chunk)) => {
                if let Some(top) = stack.last_mut() {
                    top.text.push_str(chunk.into_inner().as_ref());
                }
            }
            Ok(Event::Eof) => break,
            Ok(_) => {}
            Err(err) => return Err(anyhow!("MPD ayristirilamadi: {err}")),
        }
    }

    if stack.len() != 1 {
        return Err(anyhow!("MPD yapisi bozuk"));
    }
    // Yigin dibindeki yapay kok, belgenin tek ust seviye elemanini cocuk olarak tutar.
    let mut sentinel = stack.pop().ok_or_else(|| anyhow!("MPD yapisi bozuk"))?;
    if sentinel.children.len() != 1 {
        return Err(anyhow!("MPD yapisi bozuk"));
    }
    let root = sentinel.children.remove(0);
    if root.name != "MPD" {
        return Err(anyhow!("Manifest bir MPD belgesi degil"));
    }
    Ok(root)
}

fn resolve_base(parent: &Url, node: &XmlNode) -> Result<Url> {
    let Some(child) = node.child("BaseURL") else {
        return Ok(parent.clone());
    };
    let raw = child.text.trim();
    if raw.is_empty() {
        return Ok(parent.clone());
    }
    let text = unescape(raw)
        .map(|value| value.into_owned())
        .unwrap_or_else(|_| raw.to_string());
    parent
        .join(&text)
        .map_err(|_| anyhow!("BaseURL cozulemedi: {text}"))
}

fn resolve_url(base: &Url, raw: &str) -> Result<String> {
    let text = raw.trim();
    if text.is_empty() {
        return Err(anyhow!("Manifestte bos parca adresi"));
    }
    base.join(text)
        .map(|url| url.to_string())
        .map_err(|_| anyhow!("Parca adresi cozulemedi: {text}"))
}

/// Temsilin turu; hem yuksek bant genisligi secimi hem "ayri ses" tespiti buna dayanir.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrackKind {
    Video,
    Audio,
    Other,
}

/// SegmentTemplate: sure veya SegmentTimeline tabanli parca adresleme.
/// Alanlar `Option`: ust seviyeden miras alinan degerleri ayirt edebilmek icin.
#[derive(Clone, Debug, Default)]
pub struct Template {
    media: Option<String>,
    init: Option<String>,
    timescale: Option<u64>,
    duration: Option<u64>,
    start_number: Option<u64>,
    pto: Option<u64>,
    timeline: Vec<TimelineEntry>,
}

impl Template {
    /// Daha genel tanimin uzerine daha ozel tanimi bindirir; ozel alan kazanir.
    fn inherit(self, specific: Option<&Template>) -> Template {
        let Some(specific) = specific else {
            return self;
        };
        Template {
            media: specific.media.clone().or(self.media),
            init: specific.init.clone().or(self.init),
            timescale: specific.timescale.or(self.timescale),
            duration: specific.duration.or(self.duration),
            start_number: specific.start_number.or(self.start_number),
            pto: specific.pto.or(self.pto),
            timeline: if specific.timeline.is_empty() {
                self.timeline
            } else {
                specific.timeline.clone()
            },
        }
    }
}

/// SegmentTimeline icindeki tek `<S>` kaydi.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TimelineEntry {
    pub t: Option<u64>,
    pub d: u64,
    /// Tekrar sayisi; 0 tek parca, -1 donem sonuna kadar demektir.
    pub r: i64,
}

/// Sablonun tek parca icin ihtiyac duydugu degerler.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TemplateValues {
    pub number: u64,
    pub time: u64,
}

/// SegmentList: acik parca listesi.
#[derive(Clone, Debug, Default)]
struct SegList {
    init: Option<String>,
    media: Vec<String>,
}

/// SegmentBase: indeksli tek dosya, ya da indekssizse dosyanin tamami.
#[derive(Clone, Debug, Default)]
struct SegBase {
    index_range: Option<String>,
    init_range: Option<String>,
}

fn template_of(node: &XmlNode) -> Result<Option<Template>> {
    let Some(child) = node.child("SegmentTemplate") else {
        return Ok(None);
    };
    let mut tmpl = Template {
        media: child.attr("media").map(str::to_string),
        init: child.attr("initialization").map(str::to_string),
        timescale: child.attr("timescale").and_then(|v| v.parse().ok()),
        duration: child.attr("duration").and_then(|v| v.parse().ok()),
        start_number: child.attr("startNumber").and_then(|v| v.parse().ok()),
        pto: child
            .attr("presentationTimeOffset")
            .and_then(|v| v.parse().ok()),
        timeline: Vec::new(),
    };

    if let Some(timeline) = child.child("SegmentTimeline") {
        for entry in timeline.children_named("S") {
            let d = entry
                .attr("d")
                .and_then(|v| v.parse::<u64>().ok())
                .ok_or_else(|| anyhow!("SegmentTimeline kaydinda sure (d) yok"))?;
            tmpl.timeline.push(TimelineEntry {
                t: entry.attr("t").and_then(|v| v.parse().ok()),
                d,
                r: entry.attr("r").and_then(|v| v.parse::<i64>().ok()).unwrap_or(0),
            });
        }
    }

    Ok(Some(tmpl))
}

fn list_of(node: &XmlNode) -> Result<Option<SegList>> {
    let Some(child) = node.child("SegmentList") else {
        return Ok(None);
    };
    let mut list = SegList::default();

    if let Some(init) = child.child("Initialization") {
        if init.attr("range").is_some() {
            return Err(anyhow!(
                "SegmentList Initialization range (bayt araligi) desteklenmiyor"
            ));
        }
        list.init = init.attr("sourceURL").map(str::to_string);
    }

    for url in child.children_named("SegmentURL") {
        // Bayt aralikli parca indirilirse dosya eksik kalir; sessizce indirmek yerine hata.
        if url.attr("mediaRange").is_some() {
            return Err(anyhow!("SegmentURL mediaRange (bayt araligi) desteklenmiyor"));
        }
        let media = url
            .attr("media")
            .ok_or_else(|| anyhow!("SegmentURL media adresi yok"))?;
        list.media.push(media.to_string());
    }

    Ok(Some(list))
}

fn segbase_of(node: &XmlNode) -> Result<Option<SegBase>> {
    let Some(child) = node.child("SegmentBase") else {
        return Ok(None);
    };
    let mut base = SegBase {
        index_range: child.attr("indexRange").map(str::to_string),
        init_range: None,
    };
    if let Some(init) = child.child("Initialization") {
        base.init_range = init.attr("range").map(str::to_string);
    }
    Ok(Some(base))
}

fn kind_from_text(text: &str) -> TrackKind {
    let lower = text.to_ascii_lowercase();
    if lower.starts_with("video") {
        TrackKind::Video
    } else if lower.starts_with("audio") {
        TrackKind::Audio
    } else {
        TrackKind::Other
    }
}

fn kind_of(node: &XmlNode) -> TrackKind {
    let declared = ["contentType", "mimeType"]
        .iter()
        .find_map(|name| node.attr(name))
        .or_else(|| {
            node.child("ContentComponent")
                .and_then(|c| c.attr("contentType").or_else(|| c.attr("mimeType")))
        })
        .map(kind_from_text)
        .unwrap_or(TrackKind::Other);

    if declared != TrackKind::Other {
        return declared;
    }
    // `application/mp4` gibi turler video/ses ayrimini soylemez; cozunurluk kurtarir.
    if node.attr("width").is_some() || node.attr("height").is_some() {
        TrackKind::Video
    } else {
        TrackKind::Other
    }
}

/// `ContentProtection` CENC sifrelemesinin isaretidir; cozme yolu olmadigi icin
/// bu temsil indirilemez ve gorev net hatayla durur.
fn is_drm(node: &XmlNode) -> bool {
    node.child("ContentProtection").is_some()
}

/// Genel seviyeden ozele dogru alan bazinda miras alinan SegmentTemplate.
fn inherit_templates(levels: [Option<&Template>; 3]) -> Option<Template> {
    let mut acc: Option<Template> = None;
    for level in levels.into_iter().flatten() {
        acc = Some(match acc {
            Some(base) => base.inherit(Some(level)),
            None => level.clone(),
        });
    }
    acc
}

/// Secilen temsil.
struct Candidate {
    id: String,
    kind: TrackKind,
    bandwidth: u64,
    drm: bool,
    /// Parca adreslerinin cozulecegi taban (Period -> AdaptationSet -> Representation).
    base: Url,
    tmpl: Option<Template>,
    list: Option<SegList>,
    segbase: Option<SegBase>,
    /// SegmentBase tek dosya modunda indirilecek mutlak adres.
    single_url: Option<String>,
}

/* ---------- planlama ---------- */

/// MPD'yi cozup secilen video temsili icin indirilecek parca adreslerini
/// (init bolumu varsa basta) dondurur. Desteklenmeyen yapi tahmin edilmez,
/// net hatayla reddedilir.
pub fn plan_segments(text: &str, manifest_url: &Url) -> Result<Vec<String>> {
    let root = parse_dom(text)?;
    let mpd_base = resolve_base(manifest_url, &root)?;
    let mpd_duration = root
        .attr("mediaPresentationDuration")
        .and_then(parse_iso_duration_secs);

    let periods = root.children_named("Period");
    let usable: Vec<&XmlNode> = periods
        .iter()
        .copied()
        .filter(|period| {
            period
                .children_named("AdaptationSet")
                .iter()
                .any(|set| !set.children_named("Representation").is_empty())
        })
        .collect();
    if usable.is_empty() {
        return Err(anyhow!("MPD'de indirilebilir temsil yok"));
    }
    // Parca numaralari ve zamanlari donem bazinda yeniden baslar; birlestirmek
    // icin donemler arasi sure/numaralandirma mantigi gerekir. Tek donem destekli.
    if usable.len() > 1 {
        return Err(anyhow!(
            "Coklu Period indirilemiyor (yalnizca tek Period destekleniyor)"
        ));
    }

    let period = usable[0];
    let period_base = resolve_base(&mpd_base, period)?;
    let period_tmpl = template_of(period)?;
    let period_list = list_of(period)?;
    let period_segbase = segbase_of(period)?;
    let period_duration = period
        .attr("duration")
        .and_then(parse_iso_duration_secs)
        .or(mpd_duration);

    let mut found: Vec<Candidate> = Vec::new();
    for set in period.children_named("AdaptationSet") {
        let set_base = resolve_base(&period_base, set)?;
        let set_tmpl = template_of(set)?;
        let set_list = list_of(set)?;
        let set_segbase = segbase_of(set)?;
        let set_kind = kind_of(set);
        let set_drm = is_drm(set);

        for rep in set.children_named("Representation") {
            let rep_base = resolve_base(&set_base, rep)?;
            let rep_tmpl = template_of(rep)?;
            let rep_list = list_of(rep)?;
            let rep_segbase = segbase_of(rep)?;
            let rep_kind = {
                let kind = kind_of(rep);
                if kind == TrackKind::Other {
                    set_kind
                } else {
                    kind
                }
            };
            // SegmentBase'de tek dosyanin adresi Representation BaseURL'sidir;
            // yoksa adres manifestin kendisine duser ve indirilecek dosya kalmaz.
            let has_segbase =
                rep_segbase.is_some() || set_segbase.is_some() || period_segbase.is_some();
            let single_url = if has_segbase && rep.child("BaseURL").is_some() {
                Some(rep_base.to_string())
            } else {
                None
            };

            found.push(Candidate {
                id: rep.attr("id").unwrap_or("0").to_string(),
                kind: rep_kind,
                bandwidth: rep
                    .attr("bandwidth")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0),
                drm: set_drm || is_drm(rep),
                base: rep_base,
                tmpl: inherit_templates([
                    period_tmpl.as_ref(),
                    set_tmpl.as_ref(),
                    rep_tmpl.as_ref(),
                ]),
                // Adresleme turleri karisirsa en ozel seviye disindakiler yok sayilir;
                // tip onceligi SegmentTemplate > SegmentList > SegmentBase.
                list: rep_list.or(set_list.clone()).or(period_list.clone()),
                segbase: rep_segbase.or(set_segbase.clone()).or(period_segbase.clone()),
                single_url,
            });
        }
    }

    // Video ve ses ayri AdaptationSet'lerdeyse plan iki ayri gorev der. Ancak
    // gorev olusturma yolu (commands::enqueue_download) dosya adini manifestten
    // turetir ve tur alaninda video/ses ayrimi yok: ikinci gorev videoyla ayni
    // .mp4 adini alir, ses icerigi yanlis adla kalirdi. Bu yuzden simdilik
    // yalnizca video temsili inilir; ses parcasi indirilmez (mux yok).
    let video: Vec<&Candidate> = found
        .iter()
        .filter(|candidate| candidate.kind == TrackKind::Video)
        .collect();
    let chosen = if video.is_empty() {
        // Tur bilgisi olmayan temsiller video sayilir; ses kumesi son care
        // (ses-only manifestler de indirilebilsin).
        found
            .iter()
            .filter(|candidate| candidate.kind != TrackKind::Audio)
            .max_by_key(|candidate| candidate.bandwidth)
            .or_else(|| found.iter().max_by_key(|candidate| candidate.bandwidth))
    } else {
        video
            .iter()
            .copied()
            .max_by_key(|candidate| candidate.bandwidth)
    }
    .ok_or_else(|| anyhow!("MPD'de indirilebilir temsil yok"))?;

    if chosen.drm {
        return Err(anyhow!(DRM_ERROR));
    }

    let raw_urls = if let Some(tmpl) = &chosen.tmpl {
        template_urls(tmpl, &chosen.id, chosen.bandwidth, period_duration)?
    } else if let Some(list) = &chosen.list {
        if list.media.is_empty() {
            return Err(anyhow!("SegmentList'te parca yok"));
        }
        let mut urls = Vec::with_capacity(list.media.len() + 1);
        if let Some(init) = list.init.as_deref() {
            urls.push(init.to_string());
        }
        urls.extend(list.media.iter().cloned());
        urls
    } else if let Some(segbase) = &chosen.segbase {
        if segbase.index_range.is_some() {
            return Err(anyhow!("SegmentBase indexRange (bayt araligi) desteklenmiyor"));
        }
        if segbase.init_range.is_some() {
            return Err(anyhow!(
                "SegmentBase Initialization range (bayt araligi) desteklenmiyor"
            ));
        }
        vec![chosen
            .single_url
            .clone()
            .ok_or_else(|| anyhow!("SegmentBase icin temsil BaseURL'si yok"))?]
    } else {
        return Err(anyhow!(
            "Temsilde parca adresleme bilgisi yok (SegmentTemplate/SegmentList/SegmentBase)"
        ));
    };

    let mut urls = Vec::with_capacity(raw_urls.len());
    for raw in raw_urls {
        urls.push(resolve_url(&chosen.base, &raw)?);
    }
    Ok(urls)
}

/// SegmentTemplate'tan parca adreslerini uretir; init bolumu (varsa) basta.
fn template_urls(
    tmpl: &Template,
    rep_id: &str,
    bandwidth: u64,
    period_duration: Option<f64>,
) -> Result<Vec<String>> {
    let media = tmpl
        .media
        .as_deref()
        .ok_or_else(|| anyhow!("SegmentTemplate'ta media adresi yok"))?;
    let start_number = tmpl.start_number.unwrap_or(1);

    let values: Vec<TemplateValues> = if !tmpl.timeline.is_empty() {
        timeline_values(&tmpl.timeline, start_number)?
    } else {
        let duration = tmpl
            .duration
            .ok_or_else(|| anyhow!("SegmentTemplate'ta duration veya SegmentTimeline yok"))?;
        let timescale = tmpl.timescale.unwrap_or(1);
        if timescale == 0 || duration == 0 {
            return Err(anyhow!("SegmentTemplate'ta timescale/duration sifir olamaz"));
        }
        // Kac parca oldugu ancak donem suresinden cikarilabilir.
        let seconds = period_duration
            .ok_or_else(|| anyhow!("Donem suresi bilinmiyor: parca sayisi hesaplanamaz"))?;
        let count = ((seconds * timescale as f64) / duration as f64).ceil() as u64;
        if count == 0 {
            return Err(anyhow!("Donem suresi parca uretmeye yetmiyor"));
        }
        let pto = tmpl.pto.unwrap_or(0);
        (0..count)
            .map(|i| TemplateValues {
                number: start_number + i,
                time: pto + i * duration,
            })
            .collect()
    };

    let mut urls = Vec::with_capacity(values.len() + 1);
    if let Some(init) = tmpl.init.as_deref() {
        urls.push(expand_template(
            init,
            TemplateValues {
                number: start_number,
                time: 0,
            },
            rep_id,
            bandwidth,
        )?);
    }
    for value in values {
        urls.push(expand_template(media, value, rep_id, bandwidth)?);
    }
    Ok(urls)
}

/// SegmentTimeline'i parca numarasi/zaman ciftlerine cevirir.
pub fn timeline_values(entries: &[TimelineEntry], start_number: u64) -> Result<Vec<TemplateValues>> {
    let mut values = Vec::new();
    let mut time: u64 = 0;
    let mut number = start_number;

    for entry in entries {
        // r = -1 donemin sonuna kadar tekrar demektir; sinir bilinmedigi icin
        // tahmin etmek yerine hata verilir.
        if entry.r < 0 {
            return Err(anyhow!(
                "SegmentTimeline'da sinirsiz tekrar (r=-1) desteklenmiyor"
            ));
        }
        // `t` verilmemisse zaman onceki kayittan devam eder.
        if let Some(t) = entry.t {
            time = t;
        }
        for _ in 0..(entry.r as u64 + 1) {
            values.push(TemplateValues { number, time });
            number += 1;
            time += entry.d;
        }
    }

    if values.is_empty() {
        return Err(anyhow!("SegmentTimeline bos"));
    }
    Ok(values)
}

/// `$Number$`, `$Time$`, `$RepresentationID$`, `$Bandwidth$` ve `$$` ifadelerini
/// acar; `$Number%05d$` gibi sifir dolgulu bicim desteklenir.
pub fn expand_template(
    template: &str,
    values: TemplateValues,
    rep_id: &str,
    bandwidth: u64,
) -> Result<String> {
    let mut out = String::with_capacity(template.len() + 16);
    let mut rest = template;

    while let Some(start) = rest.find('$') {
        out.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        let end = after
            .find('$')
            .ok_or_else(|| anyhow!("Sablon ifadesi kapanmamis: {template}"))?;
        out.push_str(&substitute(&after[..end], values, rep_id, bandwidth)?);
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

fn substitute(
    token: &str,
    values: TemplateValues,
    rep_id: &str,
    bandwidth: u64,
) -> Result<String> {
    // `$$` kacis dizisi tek bir `$` uretir.
    if token.is_empty() {
        return Ok("$".to_string());
    }
    let (name, format) = match token.split_once('%') {
        Some((name, spec)) => (name, Some(format!("%{spec}"))),
        None => (token, None),
    };

    match name {
        "Number" => format_number(values.number, format.as_deref()),
        "Time" => format_number(values.time, format.as_deref()),
        "RepresentationID" => Ok(rep_id.to_string()),
        "Bandwidth" => Ok(bandwidth.to_string()),
        _ => Err(anyhow!("Desteklenmeyen sablon ifadesi: ${token}$")),
    }
}

fn format_number(value: u64, spec: Option<&str>) -> Result<String> {
    let Some(spec) = spec else {
        return Ok(value.to_string());
    };
    let body = spec.strip_prefix('%').unwrap_or(spec);
    if body == "d" {
        return Ok(value.to_string());
    }
    let width = body
        .strip_prefix('0')
        .and_then(|rest| rest.strip_suffix('d'))
        .ok_or_else(|| anyhow!("Desteklenmeyen sablon bicimi: {spec}"))?
        .parse::<usize>()
        .map_err(|_| anyhow!("Desteklenmeyen sablon bicimi: {spec}"))?;
    Ok(format!("{value:0width$}"))
}

/// ISO 8601 sure ("PT1H2M3.5S") saniyeye cevrilir. Ay/yil iceren sureler
/// MPEG-DASH'te beklenmez; yanlis hesaplamak yerine `None` doner.
fn parse_iso_duration_secs(text: &str) -> Option<f64> {
    let body = text.trim().strip_prefix('P')?;
    let (date, time) = match body.split_once('T') {
        Some((date, time)) => (date, time),
        None => (body, ""),
    };
    if date.contains('Y') || date.contains('M') {
        return None;
    }

    let mut total = 0.0;
    let mut number = String::new();
    for ch in date.chars().chain(time.chars()) {
        match ch {
            '0'..='9' | '.' => number.push(ch),
            'D' => {
                total += number.parse::<f64>().ok()? * 86_400.0;
                number.clear();
            }
            'H' => {
                total += number.parse::<f64>().ok()? * 3600.0;
                number.clear();
            }
            'M' => {
                total += number.parse::<f64>().ok()? * 60.0;
                number.clear();
            }
            'S' => {
                total += number.parse::<f64>().ok()?;
                number.clear();
            }
            _ => return None,
        }
    }
    if !number.is_empty() {
        return None;
    }
    Some(total)
}
