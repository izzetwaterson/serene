/* Serene eklentisi arka plan betigi.
 *
 * Gorevleri:
 *   1. Firefox native messaging host'u (serene-nmh.exe) ile konusmak
 *   2. Firefox'un indirmelerini devralip Serene'ye aktarmak
 *   3. Sag tik menusu ile elle yakalama
 *   4. Popup'a durum ve aktif indirme listesi sunmak
 *
 * Tasarim notu: baglanti tembel kurulur. Tarayici her acildiginda Serene'yi
 * baslatmak rahatsiz edici olurdu; uygulama yalnizca gercekten ihtiyac
 * duyuldugunda (indirme devralma, sag tik, popup) ayaga kalkar.
 */

"use strict";

const HOST_NAME = "com.serene.nmh";

const DEFAULT_SETTINGS = {
  takeover: true,
  minSizeKb: 256,
  excludedHosts: [],
  notify: true,
};

/* ------------------------------------------------------------------ */
/* Ayarlar                                                             */
/* ------------------------------------------------------------------ */

let settingsCache = null;

async function getSettings() {
  if (settingsCache) return settingsCache;
  const stored = await browser.storage.local.get("settings");
  settingsCache = { ...DEFAULT_SETTINGS, ...(stored.settings || {}) };
  return settingsCache;
}

async function saveSettings(patch) {
  const current = await getSettings();
  settingsCache = { ...current, ...patch };
  await browser.storage.local.set({ settings: settingsCache });
  return settingsCache;
}

browser.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.settings) {
    settingsCache = { ...DEFAULT_SETTINGS, ...(changes.settings.newValue || {}) };
  }
});

/* ------------------------------------------------------------------ */
/* Native messaging baglantisi                                         */
/* ------------------------------------------------------------------ */

let port = null;
let connecting = false;
let reconnectTimer = null;
let subscribed = false;

/** Baglanti kurulmadan once biriken mesajlar. */
const outbox = [];

/** reqId -> { resolve, reject, timer } */
const inflight = new Map();

let requestCounter = 0;
function nextRequestId() {
  requestCounter += 1;
  return `r${Date.now().toString(36)}-${requestCounter}`;
}

/** Son bilinen gorev listesi; popup ve rozet buradan beslenir. */
let lastTasks = [];

function scheduleReconnect(delayMs = 3000) {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    if (wanted) ensurePort();
  }, delayMs);
}

/**
 * Baglanti istegi var mi? Yalnizca gercek bir ihtiyac dogdugunda true olur;
 * boylece Firefox acilisi Serene'yi baslatmaz.
 */
let wanted = false;

function wantConnection() {
  wanted = true;
  ensurePort();
}

function ensurePort() {
  if (port || connecting) return port;

  connecting = true;
  try {
    port = browser.runtime.connectNative(HOST_NAME);
  } catch (error) {
    // Host kayitli degil ya da uygulama baslatilamadi.
    port = null;
    connecting = false;
    scheduleReconnect(5000);
    return null;
  }

  connecting = false;
  subscribed = false;

  port.onMessage.addListener(handleAppMessage);
  port.onDisconnect.addListener(() => {
    const error = browser.runtime.lastError;
    port = null;
    subscribed = false;
    // Bekleyen istekler cevapsiz kalmasin.
    for (const [reqId, entry] of inflight) {
      clearTimeout(entry.timer);
      entry.reject(new Error(error?.message || t("errorConnectionLost")));
      inflight.delete(reqId);
    }
    if (wanted) scheduleReconnect();
  });

  subscribe();
  flushOutbox();
  return port;
}

function subscribe() {
  if (!port || subscribed) return;
  subscribed = true;
  port.postMessage({ type: "subscribe" });
}

function flushOutbox() {
  if (!port) return;
  while (outbox.length) {
    const message = outbox.shift();
    try {
      port.postMessage(message);
    } catch {
      outbox.unshift(message);
      break;
    }
  }
}

function post(message) {
  if (!port) {
    outbox.push(message);
    ensurePort();
    return;
  }
  try {
    port.postMessage(message);
  } catch {
    outbox.push(message);
    port = null;
    ensurePort();
  }
}

/**
 * Baglanti YOKKEN uygulamayi baslatmayan gonderim. Mesaj tamponda bekler ve
 * baglanti kurulunca `flushOutbox` ile akar. Medya tarama bildirimleri bu
 * yolu kullanir; boylece tarayici acilisi Serene'yi ayaga kaldirmaz.
 */
function postPassive(message) {
  if (port) {
    try {
      port.postMessage(message);
      return;
    } catch {
      // Baglanti kopuyor; onDisconnect tamponu zaten ele alir.
    }
  }
  outbox.push(message);
}

/** Cevap bekleyen komut gonderir; `ack`/`error` ile eslesir. */
function sendCommand(message, timeoutMs = 15000) {
  const reqId = nextRequestId();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      inflight.delete(reqId);
      reject(new Error(t("errorTimeout")));
    }, timeoutMs);

    inflight.set(reqId, { resolve, reject, timer });
    post({ ...message, reqId });
  });
}

function handleAppMessage(message) {
  if (!message || typeof message !== "object") return;

  if (message.reqId && inflight.has(message.reqId)) {
    const entry = inflight.get(message.reqId);
    clearTimeout(entry.timer);
    inflight.delete(message.reqId);

    if (message.type === "error") {
      entry.reject(new Error(message.payload?.message || t("errorUnknown")));
    } else {
      entry.resolve(message.payload);
    }
    return;
  }

  if (message.type === "tasks") {
    lastTasks = Array.isArray(message.payload) ? message.payload : [];
    updateBadge();
    return;
  }

  if (message.type === "progress") {
    const ticks = Array.isArray(message.payload) ? message.payload : [];
    for (const tick of ticks) {
      const task = lastTasks.find((item) => item.id === tick.id);
      if (task) Object.assign(task, tick);
    }
    updateBadge();
  }
}

/**
 * Rozet: once aktif sekmenin yakalanan aday sayisi, aday yoksa aktif indirme
 * sayisi. Sekme degisiminde ve aday listesi degistiginde yeniden hesaplanir.
 */
async function updateBadge(tabId = activeTabId) {
  let candidates = 0;
  if (typeof tabId === "number" && tabId >= 0) {
    candidates = (await readCandidates(tabId)).length;
  }
  const downloads = lastTasks.filter(
    (task) => task.status === "downloading" || task.status === "queued"
  ).length;
  const count = candidates || downloads;
  browser.action.setBadgeText({ text: count ? String(count) : "" });
  browser.action.setBadgeBackgroundColor({ color: "#3D6A4B" });
}

/* ------------------------------------------------------------------ */
/* Istek basligi ipuclari (Referer / Cookie / User-Agent)              */
/* ------------------------------------------------------------------ */

/**
 * Referer icin en basit guvenilir kaynak indirmenin kendi ogesidir
 * (DownloadItem.referrer); sag tik menusunde info.pageUrl kullanilir.
 * Ikisi de bossa, istek basliklarini gozlemleyip URL -> baslik eslemesi
 * tutan bu kucuk onbellekten yararlanilir. Gozlemci engelleme yapmaz.
 */
const headerHints = new Map();
const HEADER_HINTS_MAX = 200;

function rememberRequestHeaders(details) {
  const headers = Array.isArray(details?.requestHeaders) ? details.requestHeaders : [];
  const pick = (name) =>
    headers.find((header) => String(header?.name || "").toLowerCase() === name)?.value || null;
  const referer = pick("referer");
  const userAgent = pick("user-agent");
  // Range istegi oynaticinin kendi parca cekmesidir; taramada gurultu sayilir.
  const range = pick("range") !== null;
  if (!referer && !userAgent && !range) return;

  if (!headerHints.has(details.url) && headerHints.size >= HEADER_HINTS_MAX) {
    headerHints.delete(headerHints.keys().next().value);
  }
  headerHints.set(details.url, { referer, userAgent, range });
}

if (browser.webRequest?.onBeforeSendHeaders) {
  try {
    browser.webRequest.onBeforeSendHeaders.addListener(
      rememberRequestHeaders,
      { urls: ["<all_urls>"] },
      ["requestHeaders"]
    );
  } catch {
    // Gozlemci kurulamadi; indirme ogesinin referrer alani zaten yeterli.
  }
}

/** Cerezleri tek bir `Cookie:` basligi degerine cevirir. */
async function collectCookieHeader(url) {
  if (!browser.cookies?.getAll) return null;
  try {
    const list = await browser.cookies.getAll({ url });
    if (!Array.isArray(list) || !list.length) return null;
    const pairs = list
      .filter((cookie) => cookie && cookie.name)
      .map((cookie) => `${cookie.name}=${cookie.value ?? ""}`);
    return pairs.length ? pairs.join("; ") : null;
  } catch {
    return null;
  }
}

function currentUserAgent() {
  return (typeof navigator !== "undefined" && navigator.userAgent) || null;
}

/* ------------------------------------------------------------------ */
/* Medya tarama (sniffing)                                             */
/* ------------------------------------------------------------------ */

/**
 * Yanit basliklarindan sayfadaki medyayi gozlemler; hicbir istegi engellemez
 * (engelleyici olmayan gozlemci). Yakalanan adaylar sekme basina
 * storage.session'da tutulur ve kopruye bildirilir. Bildirim baglanti YOKKEN
 * uygulamayi baslatmaz: mesaj tamponda bekler (bkz. postPassive) ve baglanti
 * kurulunca akar.
 */
const MEDIA_RESOURCE_TYPES = ["media", "xmlhttprequest", "other"];
const MEDIA_MIME_TYPES = /^(video\/|audio\/|application\/(vnd\.apple\.mpegurl|x-mpegurl|dash\+xml))/i;
const STREAM_SUFFIX_KINDS = [
  [".m3u8", "hls"],
  [".mpd", "dash"],
];
const STREAM_MIME_KINDS = {
  "application/vnd.apple.mpegurl": "hls",
  "application/x-mpegurl": "hls",
  "application/dash+xml": "dash",
};

/**
 * Gurultu esigi: 256 KB altindaki ilerlemeli medya aday sayilmaz. Akis
 * manifestleri (.m3u8/.mpd) kucuk oldugu icin esik onlara uygulanmaz.
 */
const NOISE_MIN_BYTES = 256 * 1024;
const CANDIDATE_LIMIT = 50;

/** Aktif sekme; rozet bu sekmeye gore hesaplanir. */
let activeTabId = null;

/** Sekme basina aday listesinin storage.session anahtari. */
function candidateKey(tabId) {
  return `candidates:${tabId}`;
}

function hostOf(url) {
  try {
    return new URL(url).hostname || null;
  } catch {
    return null;
  }
}

function headerValue(headers, name) {
  if (!Array.isArray(headers)) return null;
  const found = headers.find((header) => String(header?.name || "").toLowerCase() === name);
  return found?.value == null ? null : String(found.value);
}

/** Range istegi mi? Yanit basliklari bunu tasimaz, istek gozleminden bakilir. */
function hasRangeHeader(details) {
  const requestHeaders = Array.isArray(details?.requestHeaders) ? details.requestHeaders : [];
  if (requestHeaders.some((header) => String(header?.name || "").toLowerCase() === "range")) {
    return true;
  }
  return Boolean(headerHints.get(details?.url)?.range);
}

/** Yol .m3u8/.mpd ile bitiyorsa ya da MIME akis ise tur; yoksa null. */
function streamKindFor(url, mime) {
  let path;
  try {
    path = new URL(url).pathname.toLowerCase();
  } catch {
    path = String(url).toLowerCase();
  }
  for (const [suffix, kind] of STREAM_SUFFIX_KINDS) {
    if (path.endsWith(suffix)) return kind;
  }
  return STREAM_MIME_KINDS[mime] || null;
}

/** aday turu: hls/dash (akis) ya da file; medya degilse null. */
function candidateKind(url, mime) {
  const stream = streamKindFor(url, mime);
  if (stream) return stream;
  return MEDIA_MIME_TYPES.test(mime) ? "file" : null;
}

/** URL yolundan dosya adi; yol bos ise null. */
function basenameOf(url) {
  let last;
  try {
    last = new URL(url).pathname.split("/").filter(Boolean).pop() || "";
  } catch {
    return null;
  }
  if (!last) return null;
  try {
    return decodeURIComponent(last);
  } catch {
    return last;
  }
}

/** Akis adaylari duz dosyalarin onunde listelenir. */
function streamRank(kind) {
  return kind === "file" ? 1 : 0;
}

async function readCandidates(tabId) {
  if (!browser.storage?.session) return [];
  try {
    const key = candidateKey(tabId);
    const stored = await browser.storage.session.get(key);
    return Array.isArray(stored?.[key]) ? stored[key] : [];
  } catch {
    return [];
  }
}

async function writeCandidates(tabId, list) {
  if (!browser.storage?.session) return;
  try {
    await browser.storage.session.set({ [candidateKey(tabId)]: list });
  } catch {
    // Oturum deposu yoksa tarama sessizce listesiz kalir.
  }
}

async function clearCandidates(tabId) {
  if (!browser.storage?.session) return;
  try {
    await browser.storage.session.remove(candidateKey(tabId));
  } catch {
    /* yok */
  }
}

/**
 * Ayni anda gelen medya istekleri ayni anahtari okuyup yazarsa adaylar
 * kaybolur (son yazan kazanir). Bu yuzden aday deposuna dokunan tum
 * okuma-yazma islemleri tek bir zincirde siralanir.
 */
let candidateQueue = Promise.resolve();

function withCandidateLock(task) {
  const run = candidateQueue.then(task, task);
  candidateQueue = run.then(
    () => {},
    () => {}
  );
  return run;
}

function clearTabCandidates(tabId) {
  return withCandidateLock(() => clearCandidates(tabId));
}

/** Sekmenin sayfa host'u; istekte yoksa sekmeden okunur. */
async function pageHostOf(details) {
  const direct =
    hostOf(details.originUrl) || hostOf(details.documentUrl) || hostOf(details.initiator);
  if (direct) return direct;

  if (browser.tabs?.get) {
    try {
      const tab = await browser.tabs.get(details.tabId);
      const fromTab = hostOf(tab?.url);
      if (fromTab) return fromTab;
    } catch {
      /* sekme yok */
    }
  }
  return hostOf(details.url) || "";
}

/** Aday listesi degistiginde rozeti yalnizca aktif sekme icin tazele. */
function refreshBadgeFor(tabId) {
  if (activeTabId === null || activeTabId === tabId) updateBadge(tabId);
}

async function resolveActiveTab() {
  if (activeTabId !== null) return activeTabId;
  if (!browser.tabs?.query) return null;
  try {
    const tabs = await browser.tabs.query({ active: true, currentWindow: true });
    const id = Array.isArray(tabs) && tabs.length ? tabs[0].id : null;
    if (typeof id === "number") activeTabId = id;
    return activeTabId;
  } catch {
    return null;
  }
}

/** Yakalanan yeni adayi kopruye bildirir (baglanti yoksa tamponda bekler). */
function reportCapture(candidate) {
  postPassive({
    type: "capture",
    url: candidate.url,
    filename: candidate.filename,
    size: candidate.size,
    contentType: candidate.contentType,
    kind: candidate.kind,
    site: candidate.site,
  });
}

async function handleSniffedResponse(details) {
  try {
    if (!details || typeof details.url !== "string") return;
    if (!/^https?:/i.test(details.url)) return;
    if (typeof details.tabId !== "number" || details.tabId < 0) return;
    // Oynaticinin kendi parca cekmeleri listeye girmesin.
    if (hasRangeHeader(details)) return;

    const contentType = headerValue(details.responseHeaders, "content-type");
    const mime = contentType ? contentType.split(";")[0].trim().toLowerCase() : "";
    const kind = candidateKind(details.url, mime);
    if (!kind) return;

    const size = Number(headerValue(details.responseHeaders, "content-length")) || 0;
    if (kind === "file" && size > 0 && size < NOISE_MIN_BYTES) return;

    // Aday listesini tutan kritik bolge: tekilleştirme + yazim sirali olmali.
    const candidate = await withCandidateLock(async () => {
      const list = await readCandidates(details.tabId);
      // Ayni medya ayni sekmede iki kez gorunmesin.
      if (list.some((item) => item.url === details.url)) return null;

      const entry = {
        url: details.url,
        filename: basenameOf(details.url),
        size,
        contentType: mime,
        kind,
        site: await pageHostOf(details),
        ts: Date.now(),
      };

      const next = [...list, entry]
        .sort((a, b) => streamRank(a.kind) - streamRank(b.kind))
        .slice(0, CANDIDATE_LIMIT);
      await writeCandidates(details.tabId, next);
      return entry;
    });
    if (!candidate) return;

    refreshBadgeFor(details.tabId);
    reportCapture(candidate);
  } catch {
    // Tarama hicbir zaman indirmeleri ya da popup'i etkilemesin.
  }
}

if (browser.webRequest?.onHeadersReceived) {
  try {
    browser.webRequest.onHeadersReceived.addListener(
      (details) => {
        handleSniffedResponse(details);
      },
      { urls: ["<all_urls>"], types: MEDIA_RESOURCE_TYPES },
      ["responseHeaders"]
    );
  } catch {
    // API yoksa tarama sessizce kapali kalir.
  }
}

if (browser.tabs?.query) {
  resolveActiveTab().then(() => updateBadge());
}

if (browser.tabs?.onActivated) {
  browser.tabs.onActivated.addListener((info) => {
    activeTabId = typeof info?.tabId === "number" ? info.tabId : null;
    updateBadge(activeTabId);
  });
}

if (browser.tabs?.onRemoved) {
  browser.tabs.onRemoved.addListener(async (tabId) => {
    await clearTabCandidates(tabId);
    if (activeTabId === tabId) activeTabId = null;
    updateBadge(activeTabId);
  });
}

if (browser.tabs?.onUpdated) {
  browser.tabs.onUpdated.addListener(async (tabId, changeInfo) => {
    // Gezinme basladi: onceki sayfanin adaylari gecersiz.
    if (changeInfo?.status !== "loading") return;
    await clearTabCandidates(tabId);
    refreshBadgeFor(tabId);
  });
}

/* ------------------------------------------------------------------ */
/* Indirme devralma                                                    */
/* ------------------------------------------------------------------ */

/**
 * Eklentinin kendisi `downloads.download` cagirdiginda olusan kayitlar.
 * Bunlari devralmamak gerekir, yoksa sonsuz dongu olusur.
 */
const ownDownloads = new Set();
const ownDownloadUrls = new Set();

function isExcluded(url, settings) {
  let host;
  try {
    host = new URL(url).hostname.toLowerCase();
  } catch {
    return true;
  }
  return settings.excludedHosts.some((entry) => {
    const needle = String(entry || "").trim().toLowerCase();
    return needle && (host === needle || host.endsWith(`.${needle}`));
  });
}

async function handOffToSerene(item, source, refererHint) {
  // Referer onceligi: cagiranin verdigi ipucu (sag tikta pageUrl), indirme
  // ogesinin kendi alani, en son webRequest gozleminden gelen esleme.
  const hints = headerHints.get(item.url);
  const payload = {
    url: item.url,
    filename: item.filename ? item.filename.split(/[\\/]/).pop() : null,
    source,
    // Rust kopru tanimadigi alanlari yok sayar; gondermek guvenli.
    referer: refererHint || item.referrer || item.initiator || hints?.referer || null,
    cookie: await collectCookieHeader(item.url),
    userAgent: currentUserAgent(),
  };
  // Yakalanan adaylarda tur bellidir (hls/dash); normal devralmada file.
  if (item.kind) payload.kind = item.kind;

  try {
    // 20 sn'lik bekleme kullaniciyi indirmesiz birakiyordu: cevap gelmezse
    // erkenden Firefox'a geri dusulur. Soguk devralma ~3 sn surer; 8 sn bol
    // pay, ama "hicbir sey olmuyor" hissini de bitirir.
    const task = await sendCommand({ type: "enqueue", ...payload }, 8000);
    if (settingsCache?.notify !== false) {
      browser.notifications.create({
        type: "basic",
        iconUrl: browser.runtime.getURL("icons/96x96.png"),
        title: t("notifyHandedOff"),
        message: task?.filename || payload.filename || payload.url,
      });
    }
    return true;
  } catch (error) {
    return { error: String(error.message || error) };
  }
}

/** Devralma basarisiz olursa indirmeyi Firefox'a geri verir. */
async function fallbackToFirefox(item) {
  try {
    const id = await browser.downloads.download({
      url: item.url,
      filename: item.filename,
      conflictAction: "uniquify",
      saveAs: false,
    });
    ownDownloads.add(id);
    return id;
  } catch {
    return null;
  }
}

browser.downloads.onCreated.addListener(async (item) => {
  // Eklentinin kendi baslattigi indirme: devralma.
  if (ownDownloads.has(item.id) || ownDownloadUrls.has(item.url)) {
    ownDownloads.delete(item.id);
    ownDownloadUrls.delete(item.url);
    return;
  }

  const settings = await getSettings();
  if (!settings.takeover) return;
  if (isExcluded(item.url, settings)) return;

  // Bilinen boyutu esikten kucuk dosyalara karismayalim. Boyut onceden
  // bilinmiyorsa (-1) devralinir; Serene ilerlemede gosterir.
  if (item.fileSize > 0 && item.fileSize < settings.minSizeKb * 1024) return;

  wantConnection();

  try {
    await browser.downloads.cancel(item.id);
  } catch {
    // Iptal edilemediyse Firefox indirmeye devam eder; karismayalim.
    return;
  }
  try {
    await browser.downloads.erase({ id: item.id });
  } catch {
    /* kayit zaten gitti */
  }

  const result = await handOffToSerene(item, "download");
  if (result !== true) {
    // Serene almadıysa kullaniciyi indirmesiz birakma.
    await fallbackToFirefox(item);
  }
});

/* ------------------------------------------------------------------ */
/* Sag tik menusu                                                      */
/* ------------------------------------------------------------------ */

const MENU_CONTEXTS = ["link", "video", "audio", "image", "selection"];

browser.menus.create({
  id: "serene-download",
  title: t("menuDownload"),
  contexts: MENU_CONTEXTS,
});

browser.menus.onClicked.addListener(async (info) => {
  const url = info.linkUrl || info.srcUrl || (info.selectionText || "").trim();
  if (!url || !/^https?:/i.test(url)) return;

  wantConnection();

  const result = await handOffToSerene(
    {
      url,
      filename: null,
      fileSize: -1,
    },
    "menu",
    info.pageUrl || null
  );

  if (result !== true) {
    browser.notifications.create({
      type: "basic",
      iconUrl: browser.runtime.getURL("icons/96x96.png"),
      title: t("notifyHandOffFailed"),
      message: String(result.error || t("errorUnknown")),
    });
  }
});

/* ------------------------------------------------------------------ */
/* Popup ile haberlesme                                                */
/* ------------------------------------------------------------------ */

browser.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || typeof message !== "object") return undefined;

  if (message.type === "popup:state") {
    wantConnection();
    (async () => {
      let tasks = lastTasks;
      try {
        const list = await sendCommand({ type: "list" }, 8000);
        if (Array.isArray(list)) {
          lastTasks = list;
          tasks = list;
          updateBadge();
        }
      } catch {
        // Baglanti yoksa son bilinen liste gosterilir.
      }
      const tabId = await resolveActiveTab();
      const candidates = tabId === null ? [] : await readCandidates(tabId);
      sendResponse({
        connected: Boolean(port),
        tasks,
        candidates,
        settings: await getSettings(),
      });
    })();
    return true;
  }

  // Popup'tan "Indir" / "Hepsini indir": secilen adaylar Serene'ye gider.
  if (message.type === "popup:download-candidates") {
    wantConnection();
    (async () => {
      const tabId = await resolveActiveTab();
      const known = tabId === null ? [] : await readCandidates(tabId);
      const urls = Array.isArray(message.urls) ? message.urls : [];
      let queued = 0;
      const errors = [];

      for (const url of urls) {
        const candidate = known.find((item) => item.url === url) || { url, kind: "file" };
        const result = await handOffToSerene(
          {
            url: candidate.url,
            filename: candidate.filename || null,
            fileSize: candidate.size || -1,
            kind: candidate.kind || "file",
          },
          "capture"
        );
        if (result === true) queued += 1;
        else errors.push(String(result.error || t("errorUnknown")));
      }
      sendResponse({ queued, errors });
    })();
    return true;
  }

  if (message.type === "popup:open-app") {
    wantConnection();
    sendCommand({ type: "show" }, 20000)
      .then(() => sendResponse({ ok: true }))
      .catch((error) => sendResponse({ ok: false, error: String(error.message || error) }));
    return true;
  }

  if (message.type === "popup:save-settings") {
    saveSettings(message.settings || {}).then((next) => sendResponse({ settings: next }));
    return true;
  }

  return undefined;
});
