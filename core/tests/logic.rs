//! Saf mantik birim testleri: adres duzenleme, dosya adlandirma, kategori,
//! HLS/DASH playlist planlama, depo ve bekletme karari.

use reqwest::header::{COOKIE, REFERER, USER_AGENT as UA_HEADER};
use serene_core::bridge;
use serene_core::bus::EventBus;
use serene_core::category::classify;
use serene_core::clipboard::extract_url;
use serene_core::enqueue::{normalize_url, should_hold};
use serene_core::dash::{
    expand_template, plan_segments as dash_plan, timeline_values, TemplateValues, TimelineEntry,
};
use serene_core::engine::{
    build_client, build_request, filename_from_url, plan_segments, sanitize_filename, split_point,
    USER_AGENT,
};
use serene_core::hls::{aes_key_for, plan_segments as hls_plan, resolve_uri, select_variant};
use serene_core::manager::DownloadManager;
use serene_core::runtime;
use serene_core::models::{
    normalize_language, normalize_theme, Category, CaptureItem, DownloadKind, DownloadMeta,
    SegmentInfo, Settings,
};
use serene_core::store::{load_captures, save_captures, upsert_capture};

#[test]
fn classifies_by_extension() {
    assert_eq!(classify("a.mp4"), Category::Video);
    assert_eq!(classify("a.ZIP"), Category::Archive);
    assert_eq!(classify("setup.exe"), Category::Software);
    assert_eq!(classify("no-extension"), Category::Other);
    assert_eq!(classify("weird."), Category::Other);
}

#[test]
fn accepts_bare_hosts_and_adds_scheme() {
    assert_eq!(
        normalize_url("example.com/file.zip").unwrap(),
        "https://example.com/file.zip"
    );
}

#[test]
fn rejects_non_http_schemes() {
    assert!(normalize_url("ftp://example.com/a").is_err());
    assert!(normalize_url("magnet:?xt=urn:btih:abc").is_err());
    assert!(normalize_url("   ").is_err());
}

#[test]
fn splits_evenly_and_covers_every_byte() {
    const MIN_SEGMENT_BYTES: u64 = 1 << 20;
    let segs = plan_segments(1000 * MIN_SEGMENT_BYTES, 4);
    assert_eq!(segs.len(), 4);
    assert_eq!(segs[0].start, 0);
    assert_eq!(segs.last().unwrap().end, 1000 * MIN_SEGMENT_BYTES - 1);
    for pair in segs.windows(2) {
        assert_eq!(pair[0].end + 1, pair[1].start);
    }
}

#[test]
fn small_files_get_a_single_segment() {
    let segs = plan_segments(4096, 8);
    assert_eq!(segs.len(), 1);
    assert_eq!(segs[0].end, 4095);
}

#[test]
fn unknown_size_uses_streaming_sentinel() {
    let segs = plan_segments(0, 8);
    assert_eq!(segs.len(), 1);
    assert_eq!(segs[0].end, u64::MAX);
}

/// Yardimci: tek bir kapsayici aralik.
fn segment(start: u64, end: u64) -> SegmentInfo {
    SegmentInfo {
        index: 0,
        start,
        end,
        downloaded: 0,
    }
}

#[test]
fn fast_segment_is_not_split() {
    const MB: u64 = 1 << 20;
    let seg = segment(0, 16 * MB - 1);
    // Kardesleriyle ayni hizda: bolmeye gerek yok.
    assert_eq!(
        split_point(&seg, 4 * MB, 1_000_000.0, 1_000_000.0, 4, 0),
        None
    );
}

#[test]
fn slow_segment_splits_in_half() {
    const MB: u64 = 1 << 20;
    let seg = segment(0, 16 * MB - 1);
    let have = 4 * MB;
    let point = split_point(&seg, have, 100_000.0, 1_000_000.0, 4, 0).unwrap();
    // Kalan [4MB, 16MB-1] ikiye bolunur: 4MB + 6MB.
    assert_eq!(point, have + (12 * MB) / 2);
}

#[test]
fn stalled_segment_splits_even_without_peers() {
    const MB: u64 = 1 << 20;
    let seg = segment(0, 16 * MB - 1);
    // Hic bayt gelmiyor ve 3 sn gecti: tikali sayilir.
    assert!(split_point(&seg, 2 * MB, 0.0, 0.0, 4, 3_000).is_some());
    // Ayni parca ama yeni durdu: beklenir.
    assert_eq!(split_point(&seg, 2 * MB, 0.0, 0.0, 4, 1_000), None);
}

#[test]
fn split_respects_caps_and_edges() {
    const MB: u64 = 1 << 20;
    let seg = segment(0, 24 * MB - 1);
    // Tavan (16 parca) doldu: bolunmez.
    assert_eq!(
        split_point(&seg, 8 * MB, 10_000.0, 1_000_000.0, 16, 0),
        None
    );
    // Kalan 1 MiB'den kucuk: bolunmez.
    let almost = segment(0, 8 * MB + 100);
    assert_eq!(
        split_point(&almost, 8 * MB, 10_000.0, 1_000_000.0, 4, 0),
        None
    );
    // Hic bayt alinmamis: bolunmez.
    assert_eq!(split_point(&seg, 0, 0.0, 1_000_000.0, 4, 9_000), None);
    // Tek akis (boyut bilinmiyor): bolunmez.
    let stream = segment(0, u64::MAX);
    assert_eq!(
        split_point(&stream, 8 * MB, 0.0, 1_000_000.0, 4, 9_000),
        None
    );
}

#[test]
fn strips_path_traversal() {
    assert_eq!(
        sanitize_filename("../../evil.exe").as_deref(),
        Some("evil.exe")
    );
    assert_eq!(sanitize_filename("C:\\tmp\\a:b.txt").as_deref(), Some("a_b.txt"));
    assert_eq!(sanitize_filename(".."), None);
    assert_eq!(sanitize_filename(""), None);
}

#[test]
fn reads_filename_from_url() {
    assert_eq!(
        filename_from_url("https://x.dev/files/My%20Doc.pdf?token=1").as_deref(),
        Some("My Doc.pdf")
    );
    assert_eq!(filename_from_url("https://x.dev/").as_deref(), None);
}

#[test]
fn finds_url_inside_surrounding_text() {
    assert_eq!(
        extract_url("su dosyaya bak: https://x.dev/a.zip indir").as_deref(),
        Some("https://x.dev/a.zip")
    );
    assert_eq!(
        extract_url("<https://x.dev/a.zip>").as_deref(),
        Some("https://x.dev/a.zip")
    );
    assert_eq!(extract_url("hic baglanti yok"), None);
    assert_eq!(extract_url("ftp://x.dev/a"), None);
}

/// Faz 4 oncesi kaydedilmis gorev: yeni baslik alanlari yok, yine de yuklenmeli.
fn legacy_meta() -> DownloadMeta {
    serde_json::from_str(
        r#"{
            "id": "abc",
            "url": "https://x.dev/files/a.zip",
            "filename": "a.zip",
            "dest": "C:\\tmp\\a.zip",
            "temp_dir": "C:\\tmp\\.serene\\abc",
            "total": 100,
            "downloaded": 40,
            "speed": 0.0,
            "status": "paused",
            "error": null,
            "category": "archive",
            "resumable": true,
            "segments": [{ "index": 0, "start": 0, "end": 99, "downloaded": 40 }],
            "created_at": 1,
            "finished_at": null,
            "etag": "v1"
        }"#,
    )
    .expect("eski tasks.json yuklenmeli")
}

#[test]
fn legacy_task_json_without_new_fields_still_loads() {
    let meta = legacy_meta();
    assert_eq!(meta.referer, None);
    assert_eq!(meta.cookie, None);
    assert_eq!(meta.user_agent, None);
    assert_eq!(meta.kind, DownloadKind::File);
    assert_eq!(meta.source, None);
    assert!(!meta.pending);
    assert_eq!(meta.segments.len(), 1);
}

#[test]
fn browser_handoff_is_held_until_confirmed() {
    let mut settings = Settings::default();
    assert!(should_hold(Some("download"), &settings));
    assert!(should_hold(Some("menu"), &settings));

    // Medya yakalamalari panelden secilir, elle girilen adresler arayuzden:
    // ikisi de kullanici kararini zaten vermistir.
    assert!(!should_hold(Some("capture"), &settings));
    assert!(!should_hold(None, &settings));

    settings.confirm_browser_download = false;
    assert!(!should_hold(Some("download"), &settings));
}

#[test]
fn settings_without_confirm_field_ask_by_default() {
    let settings: Settings = serde_json::from_str(
        r#"{
            "downloadDir": "C:\\tmp",
            "maxConcurrent": 2,
            "connections": 4,
            "watchClipboard": false,
            "closeToTray": true
        }"#,
    )
    .expect("eski settings.json yuklenmeli");

    assert!(settings.confirm_browser_download);
}

#[test]
fn theme_field_defaults_and_normalizes() {
    let settings: Settings = serde_json::from_str(r#"{"downloadDir": "C:\\tmp"}"#)
        .expect("tema alani olmadan da yuklenmeli");
    // Alan hic yazilmamis ayar dosyalari aydinliga duser.
    assert_eq!(settings.theme, "light");

    assert_eq!(normalize_theme(" Dark "), "dark");
    assert_eq!(normalize_theme("LIGHT"), "light");
    assert_eq!(normalize_theme("System"), "system");
    assert_eq!(normalize_theme(""), "light");
    assert_eq!(normalize_theme("sepya"), "light");
}

#[test]
fn language_field_defaults_and_normalizes() {
    let settings: Settings = serde_json::from_str(r#"{"downloadDir": "C:\\tmp"}"#)
        .expect("dil alani olmadan da yuklenmeli");
    // Alan hic yazilmamis ayar dosyalari Ingilizceye duser.
    assert_eq!(settings.language, "en");

    assert_eq!(normalize_language(" EN "), "en");
    assert_eq!(normalize_language("Tr"), "tr");
    assert_eq!(normalize_language(""), "en");
    assert_eq!(normalize_language("de"), "en");
}

#[test]
fn request_builder_sets_headers_and_defaults_ua() {
    let client = build_client().unwrap();
    let mut meta = legacy_meta();

    // Baslik verilmemisse varsayilan UA'ya dusulur.
    let req = build_request(&client, &meta.url, &meta).build().unwrap();
    assert_eq!(
        req.headers().get(UA_HEADER).unwrap().to_str().unwrap(),
        USER_AGENT
    );
    assert!(req.headers().get(REFERER).is_none());
    assert!(req.headers().get(COOKIE).is_none());

    meta.referer = Some("https://x.dev/page".into());
    meta.cookie = Some("sid=1; t=2".into());
    meta.user_agent = Some("Firefox/130.0".into());

    let req = build_request(&client, &meta.url, &meta).build().unwrap();
    assert_eq!(
        req.headers().get(REFERER).unwrap().to_str().unwrap(),
        "https://x.dev/page"
    );
    assert_eq!(
        req.headers().get(COOKIE).unwrap().to_str().unwrap(),
        "sid=1; t=2"
    );
    assert_eq!(
        req.headers().get(UA_HEADER).unwrap().to_str().unwrap(),
        "Firefox/130.0"
    );
}

#[test]
fn download_kind_round_trips_through_serde() {
    for (kind, text) in [
        (DownloadKind::File, "file"),
        (DownloadKind::Hls, "hls"),
        (DownloadKind::Dash, "dash"),
    ] {
        let json = format!("\"{text}\"");
        assert_eq!(serde_json::to_string(&kind).unwrap(), json);
        assert_eq!(serde_json::from_str::<DownloadKind>(&json).unwrap(), kind);
    }
    assert_eq!(DownloadKind::default(), DownloadKind::File);
}

/* ---------- Faz 7: yakalanan medya deposu ---------- */

fn capture(url: &str) -> CaptureItem {
    CaptureItem {
        id: "c1".into(),
        url: url.into(),
        filename: "a.mp4".into(),
        size: 10,
        content_type: "video/mp4".into(),
        kind: DownloadKind::File,
        site: "x.dev".into(),
        created_at: 1,
    }
}

#[test]
fn captures_deduplicate_by_url() {
    let mut items: Vec<CaptureItem> = Vec::new();
    let (first, inserted) = upsert_capture(&mut items, capture("https://x.dev/a.mp4"));
    assert!(inserted);
    assert_eq!(items.len(), 1);

    // Ayni adres ikinci kez: yeni kayit yok, id ve icerik degismez.
    let mut repeat = capture("https://x.dev/a.mp4");
    repeat.id = "c2".into();
    repeat.filename = "baska.mp4".into();
    repeat.size = 999;
    let (again, inserted) = upsert_capture(&mut items, repeat);
    assert!(!inserted);
    assert_eq!(items.len(), 1);
    assert_eq!(again.id, first.id);
    assert_eq!(again.filename, "a.mp4");
    assert_eq!(again.size, 10);

    // Farkli adres ayri kayit olur ve en yeni kayit basa gelir.
    let (_, inserted) = upsert_capture(&mut items, capture("https://x.dev/b.mp4"));
    assert!(inserted);
    assert_eq!(items.len(), 2);
    assert_eq!(items[0].url, "https://x.dev/b.mp4");
}

#[test]
fn captures_json_round_trips() {
    let dir = std::env::temp_dir().join(format!("serene-captures-{}", std::process::id()));
    let path = dir.join("captures.json");

    let mut items: Vec<CaptureItem> = Vec::new();
    upsert_capture(&mut items, capture("https://x.dev/a.mp4"));
    let mut stream = capture("https://x.dev/v/index.m3u8");
    stream.id = "h1".into();
    stream.kind = DownloadKind::Hls;
    stream.size = 0;
    upsert_capture(&mut items, stream);
    save_captures(&path, &items);

    let loaded = load_captures(&path);
    assert_eq!(loaded.len(), 2);
    assert_eq!(loaded[0].kind, DownloadKind::Hls);
    assert_eq!(loaded[0].size, 0);
    assert_eq!(loaded[1].url, "https://x.dev/a.mp4");
    assert_eq!(loaded[1].content_type, "video/mp4");

    // Alan adlari hem eklenti hem arayuz icin camelCase olmali.
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.contains("\"contentType\""), "{text}");
    assert!(text.contains("\"createdAt\""), "{text}");

    // Eksik / bozuk dosya bos liste doner: uygulama acilmaya devam eder.
    assert!(load_captures(&dir.join("yok.json")).is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

/* ---------- Faz 5: HLS mantigi ---------- */

const MASTER: &str = "#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
high/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=960x540
mid/index.m3u8
";

fn parse_master(text: &str) -> m3u8_rs::MasterPlaylist {
    m3u8_rs::parse_master_playlist_res(text.as_bytes()).expect("master ayristirilmali")
}

fn parse_media(text: &str) -> m3u8_rs::MediaPlaylist {
    m3u8_rs::parse_media_playlist_res(text.as_bytes()).expect("medya listesi ayristirilmali")
}

fn base_url() -> reqwest::Url {
    reqwest::Url::parse("https://cdn.example.com/vod/high/index.m3u8").unwrap()
}

#[test]
fn hls_selects_highest_bandwidth_variant() {
    let master = parse_master(MASTER);
    let variant = select_variant(&master).expect("varyant secilmeli");
    assert_eq!(variant.bandwidth, 2_400_000);
    assert_eq!(variant.uri, "high/index.m3u8");
}

#[test]
fn hls_resolves_relative_and_absolute_segment_urls() {
    // Parca adresleri MEDYA LISTESI adresine gore cozulur, sayfa adresine gore degil.
    let media = parse_media(
        "#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-MAP:URI=\"init.mp4\"
#EXTINF:4.0,
seg0.ts
#EXTINF:4.0,
../ortak/seg1.ts
#EXTINF:4.0,
https://baska.example.net/d/seg2.ts
#EXT-X-ENDLIST
",
    );

    let planned = hls_plan(&media, &base_url()).unwrap();
    let urls: Vec<&str> = planned.iter().map(|p| p.url.as_str()).collect();
    assert_eq!(
        urls,
        vec![
            "https://cdn.example.com/vod/high/init.mp4",
            "https://cdn.example.com/vod/high/seg0.ts",
            "https://cdn.example.com/vod/ortak/seg1.ts",
            "https://baska.example.net/d/seg2.ts",
        ]
    );

    // Init bolumu bagimsiz bir adres olarak cozulur; goreli parca sayisi korunur.
    assert_eq!(resolve_uri(&base_url(), "seg0.ts").unwrap(), urls[1]);
    assert!(resolve_uri(&base_url(), "  ").is_err());
}

#[test]
fn hls_plans_plain_playlist_without_number_placeholders() {
    // "$Number$" gibi sablon yok: parca adlari dogrudan listede yazili.
    let media = parse_media(
        "#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
seg0.ts
#EXTINF:4.0,
seg1.ts
#EXT-X-ENDLIST
",
    );

    let planned = hls_plan(&media, &base_url()).unwrap();
    assert_eq!(planned.len(), 2);
    assert!(planned.iter().all(|p| p.key.is_none()));
    assert_eq!(planned[1].url, "https://cdn.example.com/vod/high/seg1.ts");
}

#[test]
fn hls_rejects_drm_key_with_clear_message() {
    let media = parse_media(
        "#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://ornek\"
#EXTINF:4.0,
seg0.ts
#EXT-X-ENDLIST
",
    );

    let err = hls_plan(&media, &base_url()).expect_err("DRM reddedilmeli");
    assert_eq!(err.to_string(), "Bu akis sifreli (DRM), indirilemiyor");
}

#[test]
fn hls_aes128_key_uses_attribute_or_media_sequence_iv() {
    let tag = |iv: &str| {
        format!("#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-KEY:METHOD=AES-128,URI=\"k.bin\"{iv}\n#EXTINF:4.0,\nseg0.ts\n#EXT-X-ENDLIST\n")
    };

    // IV verilmemisse medya sira numarasi 16 baytlik big-endian IV olur.
    let media = parse_media(&tag(""));
    let planned = hls_plan(&media, &base_url()).unwrap();
    let key = planned[0].key.as_ref().expect("anahtar beklenirdi");
    assert_eq!(key.uri, "https://cdn.example.com/vod/high/k.bin");
    let mut beklenen = [0u8; 16];
    beklenen[15] = 0; // media_sequence = 0
    assert_eq!(key.iv, beklenen);

    // Anahtar etiketi yalnizca bir parcaya bagli gorunse de (m3u8-rs davranisi)
    // sonraki parcalar icin de gecerli olmali; IV her parcada bir artar.
    let media = parse_media(
        "#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:7
#EXT-X-KEY:METHOD=AES-128,URI=\"k.bin\"
#EXTINF:4.0,
seg0.ts
#EXTINF:4.0,
seg1.ts
#EXTINF:4.0,
seg2.ts
#EXT-X-ENDLIST
",
    );
    let planned = hls_plan(&media, &base_url()).unwrap();
    assert_eq!(planned.len(), 3);
    for (index, item) in planned.iter().enumerate() {
        let mut beklenen = [0u8; 16];
        beklenen[15] = 7 + index as u8;
        assert_eq!(item.key.as_ref().unwrap().iv, beklenen, "parca {index}");
    }

    // IV niteligi verilirse hex olarak okunur.
    let media = parse_media(&tag(",IV=0x000102030405060708090A0B0C0D0E0F"));
    let planned = hls_plan(&media, &base_url()).unwrap();
    let iv = planned[0].key.as_ref().unwrap().iv;
    assert_eq!(iv[0], 0x00);
    assert_eq!(iv[1], 0x01);
    assert_eq!(iv[15], 0x0f);

    // Yanlis uzunluktaki IV sessizce kabul edilmez.
    let tag = m3u8_rs::parse_media_playlist_res(
        b"#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-KEY:METHOD=AES-128,URI=\"k.bin\",IV=0x0102\n#EXTINF:4.0,\nseg0.ts\n#EXT-X-ENDLIST\n",
    )
    .unwrap();
    let key_tag = tag.segments[0].key.clone().unwrap();
    assert!(aes_key_for(&key_tag, 0).is_err());
}

/* ---------- Faz 6: DASH mantigi ---------- */

#[test]
fn dash_template_expands_number_time_and_ids() {
    let values = TemplateValues {
        number: 7,
        time: 12000,
    };

    let url = expand_template("seg-$Number$-$Time$-x.mp4", values, "v1", 2_400_000).unwrap();
    assert_eq!(url, "seg-7-12000-x.mp4");

    let url = expand_template(
        "$RepresentationID$/$Bandwidth$/$Number%05d$.m4s",
        values,
        "v1",
        2_400_000,
    )
    .unwrap();
    assert_eq!(url, "v1/2400000/00007.m4s");

    // `$$` kacis dizisi tek `$` uretir.
    assert_eq!(
        expand_template("a$$b$Number$", values, "v1", 1).unwrap(),
        "a$b7"
    );

    // Taninmayan ifade ve bicim sessizce gecilmez.
    assert!(expand_template("$Bilinmeyen$", values, "v1", 1).is_err());
    assert!(expand_template("$Number%05$", values, "v1", 1).is_err());
    assert!(expand_template("seg-$Number$.m4s", values, "v1", 1).unwrap().contains("7"));
}

#[test]
fn dash_timeline_counts_segments() {
    // r tekrar sayisidir: ilk kayit 3 parca, ikincisi 1, ucuncusu 2 parca uretir.
    let entries = [
        TimelineEntry {
            t: Some(0),
            d: 2000,
            r: 2,
        },
        TimelineEntry {
            t: Some(6000),
            d: 2000,
            r: 0,
        },
        TimelineEntry {
            t: None,
            d: 1000,
            r: 1,
        },
    ];

    let values = timeline_values(&entries, 1).unwrap();
    assert_eq!(values.len(), 6);
    assert_eq!(
        values[0],
        TemplateValues {
            number: 1,
            time: 0
        }
    );
    assert_eq!(
        values[2],
        TemplateValues {
            number: 3,
            time: 4000
        }
    );
    assert_eq!(
        values[3],
        TemplateValues {
            number: 4,
            time: 6000
        }
    );
    // `t` verilmemisse zaman onceki kayittan devam eder.
    assert_eq!(
        values[4],
        TemplateValues {
            number: 5,
            time: 8000
        }
    );
    assert_eq!(
        values[5],
        TemplateValues {
            number: 6,
            time: 9000
        }
    );

    // Sinirsiz tekrar (r = -1) ve bos timeline net hata doner.
    assert!(timeline_values(
        &[TimelineEntry {
            t: None,
            d: 2000,
            r: -1
        }],
        1
    )
    .is_err());
    assert!(timeline_values(&[], 1).is_err());
}

#[test]
fn dash_plan_uses_template_of_selected_video_set() {
    // Ses kumesi one yazildi ve SegmentTemplate'i var; secim tur + bandwidth
    // ile videoda kalmali, init parcasi basta olmali.
    let mpd = r#"<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" mediaPresentationDuration="PT20S">
  <Period>
    <AdaptationSet mimeType="audio/mp4" contentType="audio">
      <Representation id="a1" bandwidth="128000">
        <SegmentTemplate timescale="1000" duration="4000" initialization="a-init.mp4" media="a-$Number$.m4s"/>
      </Representation>
    </AdaptationSet>
    <AdaptationSet mimeType="video/mp4" contentType="video">
      <Representation id="v1" bandwidth="2400000" width="1280" height="720">
        <SegmentTemplate timescale="1000" duration="4000" initialization="v-init.mp4" media="v-$Number%02d$.m4s"/>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>"#;

    let urls = dash_plan(mpd, &base_url()).unwrap();
    // 20 saniye / 4 saniyelik parca = 5 parca + init.
    assert_eq!(urls.len(), 6);
    assert_eq!(urls[0], "https://cdn.example.com/vod/high/v-init.mp4");
    assert_eq!(urls[1], "https://cdn.example.com/vod/high/v-01.m4s");
    assert_eq!(urls[5], "https://cdn.example.com/vod/high/v-05.m4s");

    // SegmentTimeline + $Time$ sablonu tek dosyada birlestirilecek adresleri verir.
    let timeline = r#"<MPD><Period><AdaptationSet mimeType="video/mp4"><Representation id="v1" bandwidth="1000">
      <SegmentTemplate timescale="1000" initialization="i-$RepresentationID$.mp4" media="t-$Time$.m4s">
        <SegmentTimeline><S t="0" d="2000" r="1"/><S t="5000" d="2000"/></SegmentTimeline>
      </SegmentTemplate>
    </Representation></AdaptationSet></Period></MPD>"#;
    let urls = dash_plan(timeline, &base_url()).unwrap();
    assert_eq!(
        urls,
        vec![
            "https://cdn.example.com/vod/high/i-v1.mp4",
            "https://cdn.example.com/vod/high/t-0.m4s",
            "https://cdn.example.com/vod/high/t-2000.m4s",
            "https://cdn.example.com/vod/high/t-5000.m4s",
        ]
    );

    // SegmentList: init (Initialization sourceURL) basta, listedeki parcalar sirayla.
    let list = r#"<MPD><Period><AdaptationSet mimeType="video/mp4"><Representation id="v1" bandwidth="1000">
      <SegmentList timescale="1000" duration="2000">
        <Initialization sourceURL="l-init.mp4"/>
        <SegmentURL media="l-1.m4s"/><SegmentURL media="l-2.m4s"/>
      </SegmentList>
    </Representation></AdaptationSet></Period></MPD>"#;
    assert_eq!(
        dash_plan(list, &base_url()).unwrap(),
        vec![
            "https://cdn.example.com/vod/high/l-init.mp4",
            "https://cdn.example.com/vod/high/l-1.m4s",
            "https://cdn.example.com/vod/high/l-2.m4s",
        ]
    );

    // Bayt aralikli SegmentURL sessizce eksik dosya uretemez.
    let ranged = r#"<MPD><Period><AdaptationSet mimeType="video/mp4"><Representation id="v1" bandwidth="1000">
      <SegmentList><SegmentURL media="l-1.m4s" mediaRange="0-99"/></SegmentList>
    </Representation></AdaptationSet></Period></MPD>"#;
    let err = dash_plan(ranged, &base_url()).unwrap_err();
    assert!(err.to_string().contains("mediaRange"), "{err}");
}

#[test]
fn dash_rejects_unsupported_structures() {
    // SegmentBase indexRange bayt araligi ister; indirici bunu yapamaz.
    let segbase = r#"<MPD><Period><AdaptationSet mimeType="video/mp4">
      <Representation id="v1" bandwidth="1000"><BaseURL>tek.mp4</BaseURL>
      <SegmentBase indexRange="0-999"/></Representation></AdaptationSet></Period></MPD>"#;
    let err = dash_plan(segbase, &base_url()).unwrap_err();
    assert!(err.to_string().contains("indexRange"), "{err}");

    // Indekssiz SegmentBase tek dosyadir: BaseURL dogrudan indirilir.
    let plain = r#"<MPD><Period><AdaptationSet mimeType="video/mp4">
      <Representation id="v1" bandwidth="1000"><BaseURL>tek.mp4</BaseURL><SegmentBase/></Representation>
      </AdaptationSet></Period></MPD>"#;
    assert_eq!(
        dash_plan(plain, &base_url()).unwrap(),
        vec!["https://cdn.example.com/vod/high/tek.mp4"]
    );

    // Coklu Period desteklenmiyor.
    let multi = r#"<MPD><Period><AdaptationSet mimeType="video/mp4"><Representation id="v1" bandwidth="1">
      <SegmentTemplate duration="4000" media="a$Number$.m4s"/></Representation></AdaptationSet></Period>
      <Period><AdaptationSet mimeType="video/mp4"><Representation id="v2" bandwidth="1">
      <SegmentTemplate duration="4000" media="b$Number$.m4s"/></Representation></AdaptationSet></Period></MPD>"#;
    let err = dash_plan(multi, &base_url()).unwrap_err();
    assert!(err.to_string().contains("Coklu Period"), "{err}");

    // r = -1 veya hicbir adresleme yoksa tahmin edilmez.
    let no_addressing = r#"<MPD mediaPresentationDuration="PT8S"><Period><AdaptationSet mimeType="video/mp4">
      <Representation id="v1" bandwidth="1"/></AdaptationSet></Period></MPD>"#;
    assert!(dash_plan(no_addressing, &base_url()).is_err());

    // ContentProtection (CENC/DRM) cozulemez: net hata beklenir.
    let drm = r#"<MPD><Period><AdaptationSet mimeType="video/mp4">
      <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011" value="cenc"/>
      <Representation id="v1" bandwidth="1"><SegmentTemplate duration="4000" media="s$Number$.m4s"/></Representation>
      </AdaptationSet></Period></MPD>"#;
    let err = dash_plan(drm, &base_url()).unwrap_err();
    assert!(err.to_string().contains("DRM"), "{err}");

    // Donem suresi olmadan kac parca oldugu hesaplanamaz.
    let no_duration = r#"<MPD><Period><AdaptationSet mimeType="video/mp4"><Representation id="v1" bandwidth="1">
      <SegmentTemplate media="s$Number$.m4s"/></Representation></AdaptationSet></Period></MPD>"#;
    assert!(dash_plan(no_duration, &base_url()).is_err());
}

/// Onay penceresi kendi motorunu kurmaz: karari `ipc.json` uzerinden calisan
/// ornegin koprusune yazar. Bu test yalitilmis bir veri klasoru acar (kosumlar
/// gibi `SERENE_DATA_DIR` ile) ve iki kararin yolunu ucdan uca yoklar.
#[test]
fn handoff_decision_travels_over_the_local_bridge() {
    let dir = std::env::temp_dir().join(format!("serene-handoff-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let downloads = dir.join("indir");
    std::fs::create_dir_all(&downloads).expect("gecici indirme klasoru");
    // `store::data_dir` her okumada degiskene bakar; baska test klasore
    // dokunmadigi icin paralel kosumda bir sey bozulmaz.
    std::env::set_var("SERENE_DATA_DIR", &dir);

    let bus = EventBus::default();
    let manager = DownloadManager::new(bus.clone()).expect("motor");
    let held: DownloadMeta = serde_json::from_str(&format!(
        r#"{{
            "id": "hf-1",
            "url": "https://ornek/ilk.bin",
            "filename": "ilk.bin",
            "dest": "{}",
            "temp_dir": "{}",
            "total": 1024,
            "downloaded": 0,
            "speed": 0.0,
            "status": "paused",
            "error": null,
            "category": "other",
            "resumable": true,
            "segments": [],
            "created_at": 1,
            "finished_at": null,
            "pending": true,
            "source": "download"
        }}"#,
        downloads.join("ilk.bin").to_string_lossy().replace('\\', "\\\\"),
        dir.join("tmp").to_string_lossy().replace('\\', "\\\\"),
    ))
    .expect("bekleyen gorev");
    manager.insert(held);

    let bridge = runtime::block_on(bridge::start(bus, manager.clone())).expect("kopru");
    assert!(dir.join(bridge::IPC_FILE).exists(), "kopru kaydi yazilmali");

    bridge::handoff_confirm("hf-1", &downloads.to_string_lossy(), "ikinci.bin", false)
        .expect("yerlestirme");
    let entry = manager.find("hf-1").expect("gorev yerinde kalmali");
    let moved = entry.meta.lock().unwrap().clone();
    assert!(!moved.pending, "karar onay beklemeyi bitirir");
    assert!(moved.dest.ends_with("ikinci.bin"), "kayit yeri: {}", moved.dest);

    bridge::handoff_cancel("hf-1").expect("vazgec");
    assert!(manager.find("hf-1").is_none(), "gorev listeden cikmali");

    bridge::cleanup(bridge.path());
    drop(manager);
    let _ = std::env::remove_var("SERENE_DATA_DIR");
    let _ = std::fs::remove_dir_all(&dir);
}
