// Serene HLS + DASH test sunucusu.
//
// Servis ettikleri:
//   /master.m3u8        -> master playlist (low 600 kbps, high 2400 kbps)
//   /high/index.m3u8    -> #EXT-X-MAP init parcasi + 6 parca (goreli adresler)
//   /low/index.m3u8     -> 6 parca (daha kucuk, goreli adresler)
//   /aes/index.m3u8     -> AES-128, IV = medya sira numarasi (nitelik yok)
//   /auth/master.m3u8   -> Referer + Cookie olmadan 403 (baslik aktarimi sinavi)
//   /drm/index.m3u8     -> METHOD=SAMPLE-AES; indirici bunu net hatayla reddetmeli
//   /dash/manifest.mpd  -> SegmentTemplate + $Number$ (video + ayri ses kumesi)
//   /dash/timeline.mpd  -> SegmentTimeline + $Time$ + $RepresentationID$
//   /dash/broken.mpd    -> SegmentBase indexRange; indirici net hatayla reddetmeli
//
// Parcalar 188 baytlik TS paket katlaridir ve her parca farkli bir bayt
// deseni tasir; boylece birlesen dosyanin icerigi parca parca dogrulanabilir.
//
// Kullanim:
//   modul olarak : import { start, EXPECTED } from "./serve_hls_test.mjs";
//   tek basina   : node scripts/serve_hls_test.mjs

import { createServer } from "node:http";
import { createCipheriv } from "node:crypto";
import { pathToFileURL } from "node:url";

export const HTTP_PORT = 8796;

/// Baslik aktarimini sinayan uclar yalnizca bu degerlerle yanit verir.
export const REQUIRED_REFERER = `http://127.0.0.1:${HTTP_PORT}/sayfa.html`;
export const REQUIRED_COOKIE = "serene=1";

const ts = (packets, byte) => Buffer.alloc(188 * packets, byte);

export const INIT = ts(4, 0x11);
export const SEGMENTS = [0, 1, 2, 3, 4, 5].map((i) => ts(20 + i, 0x40 + i));
export const LOW_SEGMENTS = [0, 1, 2, 3, 4, 5].map((i) => ts(8 + i, 0x60 + i));
export const AES_SEGMENTS = [0, 1, 2, 3, 4, 5].map((i) => ts(30 + i, 0x70 + i));
export const AES_KEY = Buffer.from("0123456789abcdef", "utf8");
export const AES_MEDIA_SEQUENCE = 7;

/* ---------- DASH ---------- */

/// fMP4 init bolumu + 5 medya parca. Ses kumesi ayri parcalardan olusur ve
/// ayri iner: video ciktisinda bulunmamali, sesin kendi dosyasinda olmali.
export const DASH_INIT = ts(4, 0x21);
export const DASH_SEGMENTS = [0, 1, 2, 3, 4].map((i) => ts(28 + i, 0x50 + i));
export const DASH_AUDIO_SEGMENTS = [0, 1, 2, 3, 4].map((i) => ts(6, 0x90 + i));

/// SegmentTimeline senaryosu: 3 + 2 parca, $Time$ ve $RepresentationID$ sablonlu.
export const DASH_TIMELINE_INIT = ts(3, 0x22);
export const DASH_TIMELINE_SEGMENTS = [0, 1, 2, 3, 4].map((i) => ts(16, 0xa2 + i));

/// Indiricinin uretmesi gereken dosya icerikleri (parcalarin sirayla birlesimi).
export const EXPECTED = {
  master: Buffer.concat([INIT, ...SEGMENTS]),
  low: Buffer.concat(LOW_SEGMENTS),
  aes: Buffer.concat(AES_SEGMENTS),
  auth: Buffer.concat([INIT, ...SEGMENTS]),
  slow: Buffer.concat([INIT, ...SEGMENTS]),
  dash: Buffer.concat([DASH_INIT, ...DASH_SEGMENTS]),
  dashAudio: Buffer.concat(DASH_AUDIO_SEGMENTS),
  dashTimeline: Buffer.concat([DASH_TIMELINE_INIT, ...DASH_TIMELINE_SEGMENTS]),
};

/// Yavas varyantta parca N, (N+1) x bu kadar gecikmeyle gonderilir; boylece
/// duraklatma aninda bazi parcalar bitmis, bazilari yarim kalir.
export const SLOW_SEGMENT_DELAY_MS = 350;

/// Sifreli parcalar: IV = 16 baytlik big-endian medya sira numarasi.
function ivFor(sequence) {
  const iv = Buffer.alloc(16);
  iv.writeBigUInt64BE(BigInt(sequence), 8);
  return iv;
}

function encrypt(plain, sequence) {
  const cipher = createCipheriv("aes-128-cbc", AES_KEY, ivFor(sequence));
  return Buffer.concat([cipher.update(plain), cipher.final()]);
}

const MASTER = `#EXTM3U
#EXT-X-VERSION:7
#EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
high/index.m3u8
`;

const HIGH_MEDIA = `#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-MAP:URI="init.ts"
${SEGMENTS.map((_, i) => `#EXTINF:4.0,\nseg${i}.ts`).join("\n")}
#EXT-X-ENDLIST
`;

const LOW_MEDIA = `#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:0
${LOW_SEGMENTS.map((_, i) => `#EXTINF:4.0,\nseg${i}.ts`).join("\n")}
#EXT-X-ENDLIST
`;

const AES_MEDIA = `#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:${AES_MEDIA_SEQUENCE}
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
${AES_SEGMENTS.map((_, i) => `#EXTINF:4.0,\nseg${i}.ts`).join("\n")}
#EXT-X-ENDLIST
`;

const DRM_MEDIA = `#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://ornek-anahtar"
#EXTINF:4.0,
seg0.ts
#EXT-X-ENDLIST
`;

const AUTH_MASTER = `#EXTM3U
#EXT-X-VERSION:7
#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
index.m3u8
`;

const SLOW_MEDIA = `#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-MAP:URI="init.ts"
${SEGMENTS.map((_, i) => `#EXTINF:4.0,\nseg${i}.ts`).join("\n")}
#EXT-X-ENDLIST
`;

const AUTH_MEDIA = `#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-MAP:URI="init.ts"
${SEGMENTS.map((_, i) => `#EXTINF:4.0,\nseg${i}.ts`).join("\n")}
#EXT-X-ENDLIST
`;

/* ---------- DASH manifestleri ---------- */

/// SegmentTemplate + $Number$; video kumesi (2400 kbps) ses kumesinden (128 kbps)
/// daha yuksek bant genisliginde, boylece secim tur + bandwidth ile sinanir.
const DASH_MANIFEST = `<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT20S" minBufferTime="PT2S">
  <Period id="1">
    <AdaptationSet mimeType="audio/mp4" contentType="audio" segmentAlignment="true">
      <Representation id="a1" bandwidth="128000" codecs="mp4a.40.2">
        <SegmentTemplate timescale="1000" duration="4000" startNumber="1" media="a-$Number$.m4s"/>
      </Representation>
    </AdaptationSet>
    <AdaptationSet mimeType="video/mp4" contentType="video" segmentAlignment="true">
      <Representation id="v1" bandwidth="2400000" width="1280" height="720" codecs="avc1.640028">
        <SegmentTemplate timescale="1000" duration="4000" startNumber="1" initialization="v-init.mp4" media="v-$Number%02d$.m4s"/>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
`;

/// SegmentTimeline + $Time$: 20 saniyede 3 + 2 parca, sure niteligi yok.
const DASH_TIMELINE = `<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT10S">
  <Period id="1">
    <AdaptationSet mimeType="video/mp4" contentType="video">
      <Representation id="v2" bandwidth="1200000" width="640" height="360">
        <SegmentTemplate timescale="1000" initialization="$RepresentationID$/i.mp4" media="$RepresentationID$/t-$Time$.m4s">
          <SegmentTimeline>
            <S t="0" d="2000" r="2"/>
            <S t="6000" d="2000" r="1"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
`;

/// Bayt araligi isteyen SegmentBase: indirici bunu net bir hatayla reddetmeli.
const DASH_BROKEN = `<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">
  <Period id="1">
    <AdaptationSet mimeType="video/mp4" contentType="video">
      <Representation id="v1" bandwidth="1000000">
        <BaseURL>v.mp4</BaseURL>
        <SegmentBase indexRange="0-999"/>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
`;

const playlist = (filename, body) => ({
  type: "application/vnd.apple.mpegurl",
  filename,
  body: Buffer.from(body, "utf8"),
});

const manifest = (filename, body) => ({
  type: "application/dash+xml",
  filename,
  body: Buffer.from(body, "utf8"),
});

const segment = (body) => ({ type: "video/mp2t", body });

/// Uc noktayi yalnizca Referer + Cookie gonderildiginde acar.
const guarded = (entry) => ({ ...entry, auth: true });

/// Govdeyi bilerek geciktirir; istemci bu sirada iptal ederse zamanlayici durur.
const delayed = (entry, delayMs) => ({ ...entry, delayMs });

function buildRoutes() {
  const routes = new Map();

  routes.set("/master.m3u8", () => playlist("hls-master.ts", MASTER));
  routes.set("/high/index.m3u8", () => playlist("hls-master.ts", HIGH_MEDIA));
  routes.set("/low/index.m3u8", () => playlist("hls-master.ts", LOW_MEDIA));
  routes.set("/high/init.ts", () => segment(INIT));
  routes.set("/aes/index.m3u8", () => playlist("hls-aes.ts", AES_MEDIA));
  routes.set("/aes/key.bin", () => segment(AES_KEY));
  routes.set("/drm/index.m3u8", () => playlist("hls-drm.ts", DRM_MEDIA));
  routes.set("/drm/seg0.ts", () => segment(ts(6, 0x80)));

  SEGMENTS.forEach((body, i) => {
    routes.set(`/high/seg${i}.ts`, () => segment(body));
    routes.set(`/auth/seg${i}.ts`, () => guarded(segment(body)));
  });
  LOW_SEGMENTS.forEach((body, i) => {
    routes.set(`/low/seg${i}.ts`, () => segment(body));
  });
  // Sifreleme IV'si parca basina medya sira numarasindan turer.
  AES_SEGMENTS.forEach((body, i) => {
    routes.set(`/aes/seg${i}.ts`, () => segment(encrypt(body, AES_MEDIA_SEQUENCE + i)));
  });

  routes.set("/auth/master.m3u8", () => guarded(playlist("hls-auth.ts", AUTH_MASTER)));
  routes.set("/auth/index.m3u8", () => guarded(playlist("hls-auth.ts", AUTH_MEDIA)));
  routes.set("/auth/init.ts", () => guarded(segment(INIT)));

  /* DASH: cikan dosya uzantisi .mp4 olmali; ad MPD'nin Content-Disposition'indan gelir. */
  routes.set("/dash/manifest.mpd", () => manifest("dash-template.mp4", DASH_MANIFEST));
  routes.set("/dash/timeline.mpd", () => manifest("dash-timeline.mp4", DASH_TIMELINE));
  routes.set("/dash/broken.mpd", () => manifest("dash-broken.mp4", DASH_BROKEN));
  routes.set("/dash/v-init.mp4", () => segment(DASH_INIT));
  DASH_SEGMENTS.forEach((body, i) => {
    routes.set(`/dash/v-${String(i + 1).padStart(2, "0")}.m4s`, () => segment(body));
  });
  // Ses kumesi ayri iner; parcalar video ciktisina degil, yanindaki dosyaya gider.
  DASH_AUDIO_SEGMENTS.forEach((body, i) => {
    routes.set(`/dash/a-${i + 1}.m4s`, () => segment(body));
  });
  routes.set("/dash/v2/i.mp4", () => segment(DASH_TIMELINE_INIT));
  DASH_TIMELINE_SEGMENTS.forEach((body, i) => {
    routes.set(`/dash/v2/t-${[0, 2000, 4000, 6000, 8000][i]}.m4s`, () => segment(body));
  });
  routes.set("/dash/v.mp4", () => segment(ts(12, 0xb0)));

  // Yavas varyant: duraklat/devam sinavi icin parcalar kademeli gecikir.
  routes.set("/slow/index.m3u8", () => playlist("hls-yavas.ts", SLOW_MEDIA));
  routes.set("/slow/init.ts", () => segment(INIT));
  SEGMENTS.forEach((body, i) => {
    routes.set(`/slow/seg${i}.ts`, () =>
      delayed(segment(body), SLOW_SEGMENT_DELAY_MS * (i + 1))
    );
  });

  return routes;
}

function hasCredentials(req) {
  const cookie = String(req.headers.cookie || "");
  return req.headers.referer === REQUIRED_REFERER && cookie.includes(REQUIRED_COOKIE);
}

/// `127.0.0.1` uzerinde dinler; cozulen nesne test betiginin ihtiyaclarini
/// (port, kapatma, beklenen baytlar) dogrudan tasir.
export function start({ port = HTTP_PORT } = {}) {
  const routes = buildRoutes();

  const server = createServer((req, res) => {
    const path = new URL(req.url, `http://127.0.0.1:${port}`).pathname;
    const handler = routes.get(path);
    if (!handler) {
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("yok");
      return;
    }

    const entry = handler(req);
    if (entry.auth && !hasCredentials(req)) {
      res.writeHead(403, { "Content-Type": "text/plain" });
      res.end("yetkisiz");
      return;
    }

    const headers = {
      "Content-Type": entry.type,
      "Content-Length": entry.body.length,
    };
    if (entry.filename) {
      headers["Content-Disposition"] = `attachment; filename="${entry.filename}"`;
    }

    const send = () => {
      if (res.writableEnded) return;
      res.writeHead(200, headers);
      res.end(entry.body);
    };

    if (entry.delayMs) {
      const timer = setTimeout(send, entry.delayMs);
      res.on("close", () => clearTimeout(timer));
    } else {
      send();
    }
  });

  return new Promise((resolve) => {
    server.listen(port, "127.0.0.1", () =>
      resolve({
        server,
        port,
        url: (path) => `http://127.0.0.1:${port}${path}`,
        close: () => new Promise((done) => server.close(done)),
      })
    );
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  start().then(({ url }) => {
    console.log(`HLS test sunucusu hazir: ${url("/master.m3u8")}`);
    console.log(`DASH test manifestleri: ${url("/dash/manifest.mpd")} ${url("/dash/timeline.mpd")}`);
    console.log(`beklenen dosya boyutu: HLS ${EXPECTED.master.length}, DASH ${EXPECTED.dash.length} bayt`);
  });
}
