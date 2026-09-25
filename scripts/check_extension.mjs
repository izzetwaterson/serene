// Serene Firefox eklentisi dogrulamasi.
//
// Firefox bu makinede kurulu olmadigi icin eklenti mantigi, WebExtension
// API'sinin taklidi uzerinden GERCEK native messaging host'una
// (serene-nmh.exe) baglanarak calistirilir. Boylece protokol, devralma
// mantigi ve geri dusme davranisi gercek uygulamayla sinanir.
//
// Dogrulananlar:
//   1. manifest.json gecerli ve basvurdugu tum dosyalar mevcut
//   2. Eklenti kimligi native host manifestindeki allowed_extensions ile ayni
//   3. Baglanti tembel: tarayici acilinca Serene baslatilmaz
//   4. Indirme devralma: Firefox indirmesi iptal edilir, Serene indirir
//   5. Kucuk dosya / haric tutulan alan adi / devralma kapali -> karisilmaz
//   6. Sag tik menusu elle yakalama
//   7. Popup durumu gorevleri listeler
//   8. Native host erisilemezse indirme Firefox'a geri verilir
//   9. Kendi baslattigi indirmeyi devralmaz (sonsuz dongu korumasi)
//  10. Istek basligi aktarimi: Referer / tek Cookie basligi / User-Agent
//      gonderilir, webRequest baslik gozlemcisi kurulur
//  11. Medya tarama (sniffing): yanit basliklari gozlemcisi kurulur, Range
//      tasiyan istek ve 256 KB altindaki ilerlemeli medya aday olmaz
//  12. .m3u8 adayi hls olarak BIR KEZ kopruye bildirilir; ayni URL tekrar
//      degerlendirilse de listeye ikinci kez girmez
//  13. Rozet aktif sekmenin aday sayisini gosterir, sekme degisiminde tazelenir
//  14. Sekme kapaninca / gezinme baslayinca adaylar silinir
//  15. Tarama tek basina native baglanti ACMAZ (uygulama baslamaz)
//
// DIKKAT: {4}. adimda `%APPDATA%\Serene\settings.json` icindeki onay ayari
// gecici olarak kapatilir (devralma pencere beklemesin diye) ve kosum sonunda
// eski haline dondurulur. `Downloads\eklenti-testi.bin` silinir.
//
// Kullanim: node scripts/check_extension.mjs

import { execSync, spawn } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { runInNewContext } from "node:vm";

const ROOT = resolve(import.meta.dirname, "..");
const EXT = join(ROOT, "extension");
// Host, uygulamayi kendi klasorunde aradigi icin kosum ikilinin YAN YANA
// oldugu yayin klasorunde calisir (deploy_flutter.mjs oraya kopyalar).
const DIR =
  process.env.SERENE_TARGET_DIR ||
  join(ROOT, "flutter_app", "build", "windows", "x64", "runner", "Debug");
const NMH = join(DIR, "serene-nmh.exe");
const APPDATA = process.env.APPDATA;
const MANIFEST_PATH = join(APPDATA, "Serene", "nmh", "com.serene.nmh.json");
const SETTINGS_PATH = join(APPDATA, "Serene", "settings.json");
const DOWNLOADS = join(process.env.USERPROFILE, "Downloads");
const HTTP_PORT = 8795;

// background.js `navigator.userAgent` okur; sandbox'ta bu deger tanimlidir,
// boylece aktarilan User-Agent dogrulanabilir.
const TEST_UA = "Serene-Test/1.0 (eklenti dogrulama)";

// Devralmada Referer, indirme ogesinin kendi alanindan gelir.
const TEST_REFERER = "http://127.0.0.1:8795/sayfa.html";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/* ---------- yerel test sunucusu ---------- */

// Varsayilan minSizeKb (256 KB) esiginin uzerinde olmali; aksi halde eklenti
// dosyayi "kucuk" sayip devralmaz ve iptal hic cagrilmaz.
const PAYLOAD = Buffer.alloc(512 * 1024, 0x5a);

function startHttpServer() {
  const server = createServer((req, res) => {
    const total = PAYLOAD.length;
    const range = req.headers.range;

    if (range) {
      const match = /bytes=(\d+)-(\d*)/.exec(range);
      const start = Number(match[1]);
      const end = match[2] ? Number(match[2]) : total - 1;
      res.writeHead(206, {
        "Content-Type": "application/octet-stream",
        "Content-Length": end - start + 1,
        "Content-Range": `bytes ${start}-${end}/${total}`,
        "Accept-Ranges": "bytes",
      });
      res.end(PAYLOAD.subarray(start, end + 1));
      return;
    }

    res.writeHead(200, {
      "Content-Type": "application/octet-stream",
      "Content-Length": total,
      "Accept-Ranges": "bytes",
    });
    res.end(PAYLOAD);
  });

  return new Promise((resolve) => server.listen(HTTP_PORT, "127.0.0.1", () => resolve(server)));
}

/* ---------- WebExtension API taklidi ---------- */

function createBrowserMock(options = {}) {
  const state = {
    nativePorts: [],
    downloads: [],
    cancelled: [],
    fallbackDownloads: [],
    notifications: [],
    badge: "",
    storage: {},
    session: {},
    listeners: {
      downloadsCreated: [],
      menuClicked: [],
      runtimeMessage: [],
      storageChanged: [],
      portMessage: [],
      portDisconnect: [],
      webRequestBeforeSend: [],
      webRequestResponse: [],
      tabsActivated: [],
      tabsRemoved: [],
      tabsUpdated: [],
    },
    lastError: undefined,
    nextDownloadId: 1,
  };

  function makePort() {
    const port = {
      onMessage: { addListener: (fn) => state.listeners.portMessage.push(fn) },
      onDisconnect: { addListener: (fn) => state.listeners.portDisconnect.push(fn) },
      postMessage: (message) => {
        port._outgoing.push(message);
        if (!port._child) return;
        const payload = Buffer.from(JSON.stringify(message), "utf8");
        const header = Buffer.alloc(4);
        header.writeUInt32LE(payload.length, 0);
        port._child.stdin.write(Buffer.concat([header, payload]));
      },
      _outgoing: [],
      _child: null,
    };

    if (options.nativeUnavailable) {
      throw new Error("native host bulunamadi (taklit)");
    }

    const child = spawn(NMH, [], { stdio: ["pipe", "pipe", "pipe"] });
    port._child = child;

    let buffer = Buffer.alloc(0);
    child.stdout.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      for (;;) {
        if (buffer.length < 4) return;
        const length = buffer.readUInt32LE(0);
        if (buffer.length < 4 + length) return;
        const body = buffer.subarray(4, 4 + length).toString("utf8");
        buffer = buffer.subarray(4 + length);
        let parsed;
        try {
          parsed = JSON.parse(body);
        } catch {
          continue;
        }
        for (const fn of state.listeners.portMessage) fn(parsed);
      }
    });

    let stderr = "";
    child.stderr.on("data", (chunk) => (stderr += chunk.toString()));
    child.on("exit", () => {
      state.lastError = stderr.trim() ? { message: stderr.trim() } : undefined;
      for (const fn of state.listeners.portDisconnect) fn();
    });

    state.nativePorts.push(port);
    return port;
  }

  const browser = {
    runtime: {
      connectNative: () => makePort(),
      getURL: (path) => `moz-extension://serene-test/${path}`,
      openOptionsPage: () => {},
      onMessage: {
        addListener: (fn) => state.listeners.runtimeMessage.push(fn),
      },
      get lastError() {
        return state.lastError;
      },
    },
    storage: {
      local: {
        get: async (key) => {
          if (typeof key === "string") {
            return key in state.storage ? { [key]: state.storage[key] } : {};
          }
          return { ...state.storage };
        },
        set: async (values) => {
          const changes = {};
          for (const [key, value] of Object.entries(values)) {
            changes[key] = { oldValue: state.storage[key], newValue: value };
            state.storage[key] = value;
          }
          for (const fn of state.listeners.storageChanged) fn(changes, "local");
        },
      },
      onChanged: { addListener: (fn) => state.listeners.storageChanged.push(fn) },
      // Tarama adaylari sekme basina oturum deposunda tutulur.
      session: {
        get: async (key) => {
          if (typeof key === "string") {
            return key in state.session ? { [key]: state.session[key] } : {};
          }
          return { ...state.session };
        },
        set: async (values) => {
          for (const [key, value] of Object.entries(values)) state.session[key] = value;
        },
        remove: async (key) => {
          delete state.session[key];
        },
      },
    },
    downloads: {
      onCreated: { addListener: (fn) => state.listeners.downloadsCreated.push(fn) },
      cancel: async (id) => {
        state.cancelled.push(id);
      },
      erase: async () => {},
      download: async (opts) => {
        const id = state.nextDownloadId++;
        state.fallbackDownloads.push({ id, ...opts });
        // Firefox davranisi: yeni indirme icin onCreated tetiklenir.
        setImmediate(() => {
          for (const fn of state.listeners.downloadsCreated) {
            fn({ id, url: opts.url, filename: opts.filename || "", fileSize: -1, incognito: false });
          }
        });
        return id;
      },
    },
    menus: {
      create: (item) => state.menus = { ...(state.menus || {}), [item.id]: item },
      onClicked: { addListener: (fn) => state.listeners.menuClicked.push(fn) },
    },
    // background.js cerezleri tek bir `Cookie:` basligi degerine cevirir.
    cookies: {
      getAll: async (opts) => [
        { name: "serene_test", value: "1", domain: "127.0.0.1", path: "/", ...opts },
        { name: "oturum", value: "abc123", domain: "127.0.0.1", path: "/" },
      ],
    },
    // Baslik ipucu gozlemcisi (engelleme yok); testte kayit oldugu dogrulanir.
    webRequest: {
      onBeforeSendHeaders: {
        addListener: (fn, filter, extra) =>
          state.listeners.webRequestBeforeSend.push({ fn, filter, extra }),
      },
      // Tarama gozlemcisi: yanit basliklari, engelleme YOK.
      onHeadersReceived: {
        addListener: (fn, filter, extra) =>
          state.listeners.webRequestResponse.push({ fn, filter, extra }),
      },
    },
    // Rozet aktif sekmenin aday sayisina gore hesaplanir; tarama sekme
    // olaylarini dinler.
    tabs: {
      query: async () => [{ id: 1, active: true, url: "http://127.0.0.1:8795/tarama.html" }],
      get: async (tabId) => ({ id: tabId, url: `http://127.0.0.1:8795/sekme${tabId}.html` }),
      onActivated: { addListener: (fn) => state.listeners.tabsActivated.push(fn) },
      onRemoved: { addListener: (fn) => state.listeners.tabsRemoved.push(fn) },
      onUpdated: { addListener: (fn) => state.listeners.tabsUpdated.push(fn) },
    },
    notifications: {
      create: (options_) => state.notifications.push(options_),
    },
    browserAction: {
      setBadgeText: ({ text }) => (state.badge = text || ""),
      setBadgeBackgroundColor: () => {},
    },
  };

  /* --- testin olaylari tetiklemesi icin yardimcilar --- */

  state.fireDownloadCreated = async (item) => {
    for (const fn of state.listeners.downloadsCreated) await fn(item);
  };

  state.fireMenuClick = async (info) => {
    for (const fn of state.listeners.menuClicked) await fn(info);
  };

  /** Istek basligi gozlemcisi: Range ipucu boyle olusur. */
  state.fireRequestHeaders = (details) => {
    for (const entry of state.listeners.webRequestBeforeSend) entry.fn(details);
  };

  /** Yanit basligi gozlemcisi: tarama burada tetiklenir (engelleme yok). */
  state.fireResponseHeaders = (details) => {
    for (const entry of state.listeners.webRequestResponse) entry.fn(details);
  };

  state.fireTabActivated = (tabId) => {
    for (const fn of state.listeners.tabsActivated) fn({ tabId });
  };

  state.fireTabRemoved = (tabId) => {
    for (const fn of state.listeners.tabsRemoved) fn(tabId, { isWindowClosing: false });
  };

  state.fireTabUpdated = (tabId, changeInfo) => {
    for (const fn of state.listeners.tabsUpdated) fn(tabId, changeInfo, { id: tabId });
  };

  state.sendRuntimeMessage = (message) =>
    new Promise((resolve) => {
      const handler = state.listeners.runtimeMessage[0];
      if (!handler) {
        resolve(undefined);
        return;
      }
      const keepOpen = handler(message, {}, resolve);
      if (keepOpen !== true) resolve(undefined);
    });

  state.waitForPort = async (timeoutMs = 30000) => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (state.nativePorts.length) return state.nativePorts[state.nativePorts.length - 1];
      await sleep(200);
    }
    throw new Error("native baglanti kurulmadi");
  };

  state.waitFor = async (predicate, timeoutMs = 30000, label = "kosul") => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (predicate()) return true;
      await sleep(200);
    }
    throw new Error(`${label} zaman asimi`);
  };

  state.closePorts = () => {
    for (const port of state.nativePorts) {
      try {
        port._child?.kill();
      } catch {
        /* kapali */
      }
    }
  };

  return { browser, state };
}

function loadBackground(browser) {
  const code = readFileSync(join(EXT, "background.js"), "utf8");
  const sandbox = {
    browser,
    console,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    URL,
    // background.js User-Agent'i buradan okur; sandbox'ta tanimli olmali.
    navigator: { userAgent: TEST_UA },
  };
  runInNewContext(code, sandbox, { filename: "background.js" });
}

/* ---------- yardimcilar ---------- */

/** Port uzerinden gonderilmis belirli kaynakli `enqueue` mesajini bulur. */
function enqueueMessage(port, source) {
  return port?._outgoing?.find(
    (message) => message.type === "enqueue" && message.source === source
  );
}

function processCount(name) {
  try {
    const out = execSync(`tasklist /FI "IMAGENAME eq ${name}" /FO CSV /NH`, {
      encoding: "utf8",
      windowsHide: true,
    });
    return out
      .split(/\r?\n/)
      .filter((line) => line.toLowerCase().includes(name.toLowerCase())).length;
  } catch {
    return 0;
  }
}

function killAll() {
  for (const name of ["serene_app.exe", "serene-nmh.exe"]) {
    try {
      execSync(`taskkill /F /IM ${name} /T`, { stdio: "ignore", windowsHide: true });
    } catch {
      /* calismiyor */
    }
  }
}

/* ---------- manifest denetimi ---------- */

function checkManifest(problems) {
  const manifest = JSON.parse(readFileSync(join(EXT, "manifest.json"), "utf8"));
  const report = { version: manifest.version, permissions: manifest.permissions.length };

  if (manifest.manifest_version !== 2) problems.push("manifest_version 2 degil");
  if (!manifest.browser_specific_settings?.gecko?.id) {
    problems.push("gecko.id tanimli degil (native messaging icin zorunlu)");
  }

  const hostManifest = JSON.parse(readFileSync(MANIFEST_PATH, "utf8"));
  const geckoId = manifest.browser_specific_settings?.gecko?.id;
  if (!hostManifest.allowed_extensions.includes(geckoId)) {
    problems.push(
      `eklenti kimligi (${geckoId}) host manifestindeki allowed_extensions ile eslesmiyor`
    );
  }
  report.geckoId = geckoId;
  report.hostAllowed = hostManifest.allowed_extensions;

  for (const permission of ["nativeMessaging", "downloads", "menus", "storage"]) {
    if (!manifest.permissions.includes(permission)) {
      problems.push(`izin eksik: ${permission}`);
    }
  }

  // Basvurulan her dosya gercekten var mi?
  const referenced = new Set();
  referenced.add(manifest.background.scripts[0]);
  referenced.add(manifest.browser_action.default_popup);
  referenced.add(manifest.options_ui.page);
  for (const size of Object.values(manifest.icons)) referenced.add(size);
  for (const size of Object.values(manifest.browser_action.default_icon)) referenced.add(size);

  const missing = [];
  for (const file of referenced) {
    if (!existsSync(join(EXT, file))) missing.push(file);
  }
  report.files = [...referenced];
  if (missing.length) problems.push(`manifest'in gosterdigi dosyalar yok: ${missing.join(", ")}`);

  // popup.html'in isaret ettigi varliklar
  const popup = readFileSync(join(EXT, "popup.html"), "utf8");
  for (const match of popup.matchAll(/(?:src|href)="([^"]+)"/g)) {
    const file = match[1];
    if (file.startsWith("http")) continue;
    if (!existsSync(join(EXT, file))) problems.push(`popup.html dosyayi bulamiyor: ${file}`);
  }

  // options.html ayni sekilde
  const options = readFileSync(join(EXT, "options.html"), "utf8");
  for (const match of options.matchAll(/(?:src|href)="([^"]+)"/g)) {
    const file = match[1];
    if (file.startsWith("http")) continue;
    if (!existsSync(join(EXT, file))) problems.push(`options.html dosyayi bulamiyor: ${file}`);
  }

  // popup.js'in aradigi id'ler html'de var mi?
  const popupJs = readFileSync(join(EXT, "popup.js"), "utf8");
  const missingIds = [];
  for (const match of popupJs.matchAll(/getElementById\("([^"]+)"\)/g)) {
    if (!popup.includes(`id="${match[1]}"`)) missingIds.push(match[1]);
  }
  if (missingIds.length) {
    problems.push(`popup.js'in aradigi id'ler eksik: ${missingIds.join(", ")}`);
  }

  const optionsJs = readFileSync(join(EXT, "options.js"), "utf8");
  const missingOptionIds = [];
  for (const match of optionsJs.matchAll(/getElementById\("([^"]+)"\)/g)) {
    if (!options.includes(`id="${match[1]}"`)) missingOptionIds.push(match[1]);
  }
  if (missingOptionIds.length) {
    problems.push(`options.js'in aradigi id'ler eksik: ${missingOptionIds.join(", ")}`);
  }

  return report;
}

/* ---------- ana akis ---------- */

async function main() {
  const report = {};
  const problems = [];
  let failed = false;

  /* {4} adiminda yazilan ayarin kosum oncesi hali; sonunda geri konur. */
  let settingsBackup = null;
  let settingsTouched = false;

  killAll();
  await sleep(800);
  try {
    rmSync(join(DOWNLOADS, "eklenti-testi.bin"), { force: true });
  } catch {
    /* yok */
  }

  const httpServer = await startHttpServer();

  try {
    /* 1-2. Manifest */
    report.manifest = checkManifest(problems);
    console.log(
      `manifest v${report.manifest.version}: ${report.manifest.permissions} izin, kimlik=${report.manifest.geckoId}`
    );
    console.log(`host allowed_extensions: ${JSON.stringify(report.manifest.hostAllowed)}`);

    /* 3. Tembel baglanti: yuklenince uygulama baslamamali */
    const mock = createBrowserMock();
    loadBackground(mock.browser);
    await sleep(2500);

    report.lazyStart = {
      nativePorts: mock.state.nativePorts.length,
      sereneRunning: processCount("serene_app.exe"),
    };
    console.log(
      `yukleme sonrasi: native baglanti=${report.lazyStart.nativePorts}, serene_app.exe=${report.lazyStart.sereneRunning}`
    );
    if (report.lazyStart.nativePorts !== 0) {
      problems.push("eklenti yuklenir yuklenmez native baglanti kurdu (tembel olmali)");
    }
    if (report.lazyStart.sereneRunning !== 0) {
      problems.push("eklenti yuklenir yuklenmez Serene'yi baslatti");
    }

    /* 3b. Medya tarama (sniffing) — henuz baglanti yok */
    const SNIFF_TAB = 1;
    const SNIFF_SITE = "127.0.0.1";
    const sniffUrls = {
      file: `http://127.0.0.1:${HTTP_PORT}/film.mp4`,
      stream: `http://127.0.0.1:${HTTP_PORT}/canli/akis.m3u8`,
      ranged: `http://127.0.0.1:${HTTP_PORT}/parcali.mp4`,
      small: `http://127.0.0.1:${HTTP_PORT}/kucuk.mp4`,
    };
    const sessionCandidates = (tabId) => mock.state.session[`candidates:${tabId}`] || [];

    const responseObserver = mock.state.listeners.webRequestResponse[0];
    report.sniffObserver = {
      count: mock.state.listeners.webRequestResponse.length,
      extra: responseObserver?.extra,
      types: responseObserver?.filter?.types,
    };
    console.log(
      `medya gozlemcisi: ${report.sniffObserver.count} kayit, extra=${JSON.stringify(report.sniffObserver.extra)}, turler=${JSON.stringify(report.sniffObserver.types)}`
    );
    if (report.sniffObserver.count !== 1) {
      problems.push("webRequest yanit gozlemcisi kurulmadi");
    }
    if (JSON.stringify(report.sniffObserver.extra) !== JSON.stringify(["responseHeaders"])) {
      problems.push("yanit gozlemcisi extraInfoSpec 'responseHeaders' degil");
    }
    if (!(report.sniffObserver.types || []).includes("media")) {
      problems.push("yanit gozlemcisi kaynak turleri media icermiyor");
    }

    const sniff = (url, { mime = "video/mp4", length = 4 * 1024 * 1024 } = {}) =>
      mock.state.fireResponseHeaders({
        url,
        tabId: SNIFF_TAB,
        type: "xmlhttprequest",
        method: "GET",
        originUrl: "http://127.0.0.1:8795/tarama.html",
        responseHeaders: [
          { name: "Content-Type", value: mime },
          { name: "Content-Length", value: String(length) },
        ],
      });

    // Range tasiyan istek: oynaticinin kendi parca cekmesi, atlanmali.
    mock.state.fireRequestHeaders({
      url: sniffUrls.ranged,
      requestHeaders: [{ name: "Range", value: "bytes=0-1048575" }],
    });
    await sniff(sniffUrls.ranged);
    // 256 KB altindaki ilerlemeli medya atlanmali.
    await sniff(sniffUrls.small, { length: 100 * 1024 });
    // Gercek adaylar: duz dosya + akis (m3u8 kucuk olsa da aday olur).
    await sniff(sniffUrls.file);
    await sniff(sniffUrls.stream, { mime: "application/vnd.apple.mpegurl", length: 900 });
    // Ikinci degerlendirme turu: ayni URL yine bildirilmemeli.
    await sniff(sniffUrls.file);
    await sniff(sniffUrls.stream, { mime: "application/vnd.apple.mpegurl", length: 900 });

    await mock.state.waitFor(
      () => sessionCandidates(SNIFF_TAB).length === 2,
      5000,
      "aday listesi"
    );

    const sniffed = sessionCandidates(SNIFF_TAB);
    report.sniffCandidates = sniffed.map((item) => ({ kind: item.kind, url: item.url }));
    report.sniffBadge = mock.state.badge;
    console.log(`sekme ${SNIFF_TAB} adaylari: ${JSON.stringify(report.sniffCandidates)}`);
    console.log(`rozet (aktif sekme): "${report.sniffBadge}"`);

    if (sniffed.length !== 2) problems.push(`aday listesi 2 olmali, ${sniffed.length} bulundu`);
    if (sniffed[0]?.kind !== "hls") problems.push("akis adayi listenin basinda degil");
    if (sniffed.some((item) => item.url === sniffUrls.ranged)) {
      problems.push("Range tasiyan istek aday oldu");
    }
    if (sniffed.some((item) => item.url === sniffUrls.small)) {
      problems.push("256 KB altindaki ilerlemeli medya aday oldu");
    }
    if (sniffed.filter((item) => item.url === sniffUrls.stream).length !== 1) {
      problems.push("ayni akis adayi listeye iki kez girdi");
    }
    if (mock.state.badge !== "2") {
      problems.push(`rozet aday sayisini gostermedi (${mock.state.badge})`);
    }

    // Tarama tek basina baglanti acmamali: uygulama baslamaz, mesaj tamponda.
    report.sniffLazy = {
      nativePorts: mock.state.nativePorts.length,
      sereneRunning: processCount("serene_app.exe"),
    };
    console.log(
      `tarama sonrasi: native baglanti=${report.sniffLazy.nativePorts}, serene_app.exe=${report.sniffLazy.sereneRunning}`
    );
    if (report.sniffLazy.nativePorts !== 0) {
      problems.push("tarama native baglanti acti (uygulama baslatilmamali)");
    }
    if (report.sniffLazy.sereneRunning !== 0) {
      problems.push("tarama Serene'yi baslatti");
    }

    /* 4. Indirme devralma */
    // Devralinan indirme artik "Indirme Bilgileri" penceresiyle onay bekler
    // (bkz. should_hold). Bu kosum arayuzu surmuyor, bu yuzden uygulama
    // baslamadan once ayar kapatilir; pencere davranisi ayri kosumda
    // (scripts/check_handoff.mjs) dogrulanir. Ayar kosum sonunda geri konur.
    try {
      settingsBackup = existsSync(SETTINGS_PATH) ? readFileSync(SETTINGS_PATH, "utf8") : null;
      settingsTouched = true;
      mkdirSync(join(APPDATA, "Serene"), { recursive: true });
      const current = settingsBackup ? JSON.parse(settingsBackup) : {};
      writeFileSync(
        SETTINGS_PATH,
        JSON.stringify({ ...current, confirmBrowserDownload: false }, null, 2),
        "utf8"
      );
      console.log("onay penceresi ayari kosum icin kapatildi");
    } catch (error) {
      problems.push(`onay penceresi ayari kapatilamadi: ${error.message}`);
    }

    const url = `http://127.0.0.1:${HTTP_PORT}/eklenti-testi.bin`;
    await mock.state.fireDownloadCreated({
      id: 101,
      url,
      filename: "eklenti-testi.bin",
      fileSize: PAYLOAD.length,
      referrer: TEST_REFERER,
      incognito: false,
    });

    await mock.state.waitFor(() => mock.state.cancelled.includes(101), 20000, "iptal");
    console.log(`Firefox indirmesi iptal edildi: ${JSON.stringify(mock.state.cancelled)}`);
    if (!mock.state.cancelled.includes(101)) problems.push("devralma icin indirme iptal edilmedi");

    const port = await mock.state.waitForPort(30000);
    console.log(`native baglanti kuruldu, giden mesajlar: ${port._outgoing.length}`);

    /* 4a. Tarama bildirimleri: baglanti kurulunca tampondan akar, her aday
     *     ayni sekme icin tam olarak BIR KEZ bildirilir. */
    await mock.state.waitFor(
      () => port._outgoing.filter((message) => message.type === "capture").length === 2,
      5000,
      "yakalama bildirimleri"
    );
    const captures = port._outgoing.filter((message) => message.type === "capture");
    report.captures = captures.map((item) => ({
      kind: item.kind,
      url: item.url,
      filename: item.filename,
      size: item.size,
      contentType: item.contentType,
      site: item.site,
    }));
    console.log(`kopruye bildirilen yakalamalar: ${JSON.stringify(report.captures)}`);
    if (captures.length !== 2) {
      problems.push(`2 yakalama bildirilmeli, ${captures.length} bulundu`);
    }
    const hlsCaptures = captures.filter((item) => item.url === sniffUrls.stream);
    if (hlsCaptures.length !== 1) {
      problems.push(`akis adayi kopruye ${hlsCaptures.length} kez bildirildi`);
    }
    if (hlsCaptures[0]?.kind !== "hls") problems.push("akis adayi kind=hls degil");
    const fileCapture = captures.find((item) => item.url === sniffUrls.file);
    if (!fileCapture) {
      problems.push("dosya adayi kopruye bildirilmedi");
    } else {
      if (fileCapture.kind !== "file") problems.push("dosya adayi kind=file degil");
      if (fileCapture.filename !== "film.mp4") {
        problems.push(`filename alani yanlis (${fileCapture.filename})`);
      }
      if (fileCapture.size !== 4 * 1024 * 1024) {
        problems.push(`size alani Content-Length ile uyusmuyor (${fileCapture.size})`);
      }
      if (fileCapture.contentType !== "video/mp4") {
        problems.push(`contentType alani MIME ile uyusmuyor (${fileCapture.contentType})`);
      }
      if (fileCapture.site !== SNIFF_SITE) {
        problems.push(`site alani sayfa host'u degil (${fileCapture.site})`);
      }
    }

    /* 4b. Istek basligi aktarimi (Referer / Cookie / User-Agent) */
    const takeoverEnqueue = enqueueMessage(port, "download");
    report.headers = {
      referer: takeoverEnqueue?.referer ?? null,
      cookie: takeoverEnqueue?.cookie ?? null,
      userAgent: takeoverEnqueue?.userAgent ?? null,
    };
    console.log(
      `devralma basliklari: referer=${report.headers.referer}, cookie=${report.headers.cookie}, ua=${report.headers.userAgent}`
    );
    if (report.headers.referer !== TEST_REFERER) {
      problems.push("devralmada indirme ogesinin Referer'i aktarilmadi");
    }
    if (!String(report.headers.cookie || "").includes("serene_test=1")) {
      problems.push("cerezler tek Cookie basligina cevrilmedi");
    }
    if (report.headers.userAgent !== TEST_UA) {
      problems.push("User-Agent aktarilmadi");
    }

    report.headerObserver = mock.state.listeners.webRequestBeforeSend.length;
    console.log(`webRequest baslik gozlemcisi: ${report.headerObserver} kayit`);
    if (report.headerObserver !== 1) {
      problems.push("webRequest baslik gozlemcisi kurulmadi");
    }
    try {
      for (const entry of mock.state.listeners.webRequestBeforeSend) {
        entry.fn({
          url,
          requestHeaders: [
            { name: "Referer", value: "http://127.0.0.1:8795/gozlem.html" },
            { name: "User-Agent", value: TEST_UA },
          ],
        });
      }
    } catch (error) {
      problems.push(`webRequest gozlemcisi hata verdi: ${error.message}`);
    }

    await mock.state.waitFor(
      () => mock.state.storage.settings === undefined,
      1000,
      "bekleme"
    ).catch(() => {});

    // Serene indirmeyi tamamlayana kadar bekle.
    const filePath = join(DOWNLOADS, "eklenti-testi.bin");
    const deadline = Date.now() + 60000;
    let fileOk = false;
    while (Date.now() < deadline) {
      if (existsSync(filePath) && readFileSync(filePath).length === PAYLOAD.length) {
        fileOk = true;
        break;
      }
      await sleep(400);
    }
    report.downloadViaExtension = { fileExists: fileOk, expectedBytes: PAYLOAD.length };
    console.log(`Serene dosyayi indirdi: ${fileOk} (${PAYLOAD.length} bayt)`);
    if (!fileOk) problems.push("devralinan indirme Serene tarafindan tamamlanmadi");

    report.notifications = mock.state.notifications.length;
    if (report.notifications < 1) problems.push("aktarim bildirimi gosterilmedi");

    /* 5. Karismamasi gereken durumlar */
    const before = mock.state.cancelled.length;
    await mock.state.fireDownloadCreated({
      id: 102,
      url,
      filename: "kucuk.bin",
      fileSize: 1024,
      incognito: false,
    });
    report.smallFileSkipped = mock.state.cancelled.length === before;
    console.log(`kucuk dosya atlandi: ${report.smallFileSkipped}`);
    if (!report.smallFileSkipped) problems.push("kucuk dosya yine de devralindi");

    await mock.state.sendRuntimeMessage({
      type: "popup:save-settings",
      settings: { excludedHosts: ["127.0.0.1"] },
    });
    await sleep(300);
    await mock.state.fireDownloadCreated({
      id: 103,
      url,
      filename: "haric.bin",
      fileSize: PAYLOAD.length,
      incognito: false,
    });
    report.excludedSkipped = mock.state.cancelled.length === before;
    console.log(`haric tutulan alan adi atlandi: ${report.excludedSkipped}`);
    if (!report.excludedSkipped) problems.push("haric tutulan alan adi devralindi");

    await mock.state.sendRuntimeMessage({
      type: "popup:save-settings",
      settings: { excludedHosts: [], takeover: false },
    });
    await sleep(300);
    await mock.state.fireDownloadCreated({
      id: 104,
      url,
      filename: "kapali.bin",
      fileSize: PAYLOAD.length,
      incognito: false,
    });
    report.takeoverOffSkipped = mock.state.cancelled.length === before;
    console.log(`devralma kapaliyken atlandi: ${report.takeoverOffSkipped}`);
    if (!report.takeoverOffSkipped) problems.push("devralma kapaliyken yine devralindi");

    await mock.state.sendRuntimeMessage({
      type: "popup:save-settings",
      settings: { takeover: true, excludedHosts: [] },
    });
    await sleep(300);

    /* 6. Sag tik menusu */
    const menuPage = "http://127.0.0.1:8795/menu-sayfa.html";
    const cancelledBeforeMenu = mock.state.cancelled.length;
    await mock.state.fireMenuClick({
      linkUrl: url,
      pageUrl: menuPage,
      menuItemId: "serene-download",
    });
    report.menuEnqueued = mock.state.cancelled.length === cancelledBeforeMenu;
    console.log("sag tik menusu yakalamayi tetikledi (Firefox indirmesi yok)");
    await sleep(3000);

    const menuEnqueue = enqueueMessage(port, "menu");
    report.menuReferer = menuEnqueue?.referer ?? null;
    console.log(`menu basliklari: referer=${report.menuReferer}`);
    if (report.menuReferer !== menuPage) {
      problems.push("sag tik menusunde info.pageUrl Referer olarak aktarilmadi");
    }

    /* 7. Popup durumu */
    const popupState = await mock.state.sendRuntimeMessage({ type: "popup:state" });
    report.popupState = {
      connected: popupState?.connected,
      taskCount: Array.isArray(popupState?.tasks) ? popupState.tasks.length : null,
      candidates: Array.isArray(popupState?.candidates) ? popupState.candidates.length : null,
      candidateKinds: Array.isArray(popupState?.candidates)
        ? popupState.candidates.map((item) => item.kind)
        : null,
    };
    console.log(
      `popup durumu: bagli=${report.popupState.connected}, gorev=${report.popupState.taskCount}, aday=${report.popupState.candidates} ${JSON.stringify(report.popupState.candidateKinds)}`
    );
    if (!popupState?.connected) problems.push("popup bagli gormedi");
    if (!report.popupState.taskCount) problems.push("popup gorevleri listelemedi");
    if (report.popupState.candidates !== 2) {
      problems.push(`popup yakalanan adaylari listelemedi (${report.popupState.candidates})`);
    }
    if (report.popupState.candidateKinds?.[0] !== "hls") {
      problems.push("popup'ta akis adayi once gelmiyor");
    }

    const openResult = await mock.state.sendRuntimeMessage({ type: "popup:open-app" });
    report.openAppOk = openResult?.ok === true;
    console.log(`"Serene'yi Ac" sonucu: ${report.openAppOk}`);
    if (!report.openAppOk) problems.push("'Serene'yi Ac' komutu basarisiz");

    /* 7b. Toplu indirme mesaji ve sekme olaylari */
    const bulkEmpty = await mock.state.sendRuntimeMessage({
      type: "popup:download-candidates",
      urls: [],
    });
    report.bulkHandler = bulkEmpty?.queued === 0;
    console.log(`"Hepsini indir" mesaji yanitlandi: ${report.bulkHandler}`);
    if (!report.bulkHandler) problems.push("popup:download-candidates yanit vermedi");

    // Arka plandaki sekmede yakalama: rozet o sekme icin hesaplanmaz.
    mock.state.fireTabActivated(2);
    await mock.state.waitFor(() => mock.state.badge !== "2", 5000, "rozet (sekme 2)");
    const tab2Stream = `http://127.0.0.1:${HTTP_PORT}/dizi.mpd`;
    mock.state.fireResponseHeaders({
      url: tab2Stream,
      tabId: 2,
      type: "other",
      originUrl: "http://127.0.0.1:8795/dizi-sayfa.html",
      responseHeaders: [
        { name: "Content-Type", value: "application/dash+xml" },
        { name: "Content-Length", value: "2048" },
      ],
    });
    await mock.state.waitFor(
      () => sessionCandidates(2).length === 1,
      5000,
      "sekme 2 adayi"
    );
    await mock.state.waitFor(() => mock.state.badge === "1", 5000, "rozet (sekme 2 adayi)");
    const dashCandidate = sessionCandidates(2)[0];
    report.dashCandidate = { kind: dashCandidate.kind, site: dashCandidate.site };
    console.log(`sekme 2 adayi: ${JSON.stringify(report.dashCandidate)}`);
    if (dashCandidate.kind !== "dash") problems.push("mpd adayi dash olarak isaretlenmedi");
    if (dashCandidate.site !== SNIFF_SITE) {
      problems.push(`site alani sekme 2 host'u degil (${dashCandidate.site})`);
    }

    // Sekme kapaninca adaylari silinir.
    mock.state.fireTabRemoved(2);
    await mock.state.waitFor(
      () => mock.state.session["candidates:2"] === undefined,
      5000,
      "sekme kapanisi temizligi"
    );
    report.closedTabCleared = mock.state.session["candidates:2"] === undefined;
    console.log(`kapanan sekmenin adaylari silindi: ${report.closedTabCleared}`);
    if (!report.closedTabCleared) problems.push("sekme kapaninca adaylar silinmedi");

    // Aktif sekme 1'e donunce rozet aday sayisini gosterir.
    mock.state.fireTabActivated(1);
    await mock.state.waitFor(() => mock.state.badge === "2", 5000, "rozet (sekme 1)");
    report.badgeOnActivate = mock.state.badge;
    console.log(`sekme degisiminde rozet: "${report.badgeOnActivate}"`);
    if (report.badgeOnActivate !== "2") {
      problems.push("sekme degisiminde rozet tazelenmedi");
    }

    // Gezinme basladi: onceki sayfanin adaylari gecersiz.
    mock.state.fireTabUpdated(1, { status: "loading" });
    await mock.state.waitFor(
      () => sessionCandidates(1).length === 0,
      5000,
      "gezinme temizligi"
    );
    report.reloadCleared = sessionCandidates(1).length === 0;
    console.log(`gezinmede adaylar temizlendi: ${report.reloadCleared}`);
    if (!report.reloadCleared) problems.push("gezinmede adaylar temizlenmedi");

    mock.state.closePorts();
    killAll();
    await sleep(1500);

    /* 8. Native host yoksa Firefox'a geri dusme */
    const brokenMock = createBrowserMock({ nativeUnavailable: true });
    loadBackground(brokenMock.browser);
    await sleep(500);

    await brokenMock.state.fireDownloadCreated({
      id: 201,
      url,
      filename: "geri-dusme.bin",
      fileSize: PAYLOAD.length,
      incognito: false,
    });
    await sleep(3000);

    report.fallback = {
      cancelled: brokenMock.state.cancelled.includes(201),
      reDownloaded: brokenMock.state.fallbackDownloads.length,
    };
    console.log(
      `geri dusme: iptal=${report.fallback.cancelled}, Firefox'a verildi=${report.fallback.reDownloaded}`
    );
    if (!report.fallback.cancelled) problems.push("iptal edilmedi (geri dusme testi)");
    if (report.fallback.reDownloaded !== 1) {
      problems.push(`indirme Firefox'a geri verilmedi (${report.fallback.reDownloaded})`);
    }

    /* 9. Kendi baslattigi indirmeyi devralmamali */
    await sleep(1500);
    const cancelledAfterFallback = brokenMock.state.cancelled.length;
    report.ownDownloadGuard = brokenMock.state.cancelled.length === cancelledAfterFallback;
    console.log(
      `kendi baslattigi indirme tekrar devralinmadi: ${report.ownDownloadGuard} (iptal sayisi=${brokenMock.state.cancelled.length})`
    );
    if (brokenMock.state.cancelled.length > 1) {
      problems.push("kendi baslattigi indirme tekrar iptal edildi (sonsuz dongu riski)");
    }

    brokenMock.state.closePorts();
    killAll();
    await sleep(1000);

    console.log("");
    console.log(JSON.stringify(report, null, 2));
    console.log("");
    if (problems.length) {
      failed = true;
      console.log(`BASARISIZ: ${problems.join("; ")}`);
    } else {
      console.log(
        "BASARILI: eklenti manifesti, devralma, medya taramasi, menu ve geri dusme dogrulandi"
      );
    }
  } catch (error) {
    failed = true;
    console.log("");
    console.log(`BASARISIZ: ${error.message}`);
  } finally {
    killAll();
    await sleep(500);
    try {
      rmSync(join(DOWNLOADS, "eklenti-testi.bin"), { force: true });
    } catch {
      /* yok */
    }
    // Uygulama kapandiktan sonra ayar dosyasi eski haline dondurulur.
    if (settingsTouched) {
      try {
        if (settingsBackup === null) rmSync(SETTINGS_PATH, { force: true });
        else writeFileSync(SETTINGS_PATH, settingsBackup, "utf8");
      } catch (error) {
        console.log(`uyari: settings.json geri konulamadi (${error.message})`);
      }
    }
    httpServer.close();
  }

  process.exit(failed ? 1 : 0);
}

main().catch((error) => {
  console.log(`beklenmeyen hata: ${error.message}`);
  process.exit(2);
});
