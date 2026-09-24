// Serene "Tarayicidan" paneli (Faz 7) arayuz dogrulamasi.
//
// Gercek uygulama WebView2 uzak hata ayiklama portu ile baslatilir; arayuz CDP
// uzerinden surulur ve yerel kopruye gercek bir istemci baglanip eklenti gibi
// `capture` mesajlari gonderir. Boylece hem kopruden gelen olaylarin hem de
// kullanici tiklamalarinin paneli dogru guncelledigi kanitlanir.
//
// Dogrulananlar:
//   1. Sol menude "Tarayicidan" girdisi ve rozeti var; baslangicta bos gorunum
//   2. Girde tiklaninca yakalananlar gorunumu acilir ve sekme vurgulanir
//   3. Kopruden istemci baglaninca basliktaki gosterge yesile doner; istemci
//      ayrilinca griye duser
//   4. Yeni yakalama rozeti ve listeyi gunceller, bildirim karti cikar
//   5. Karttaki "Indir" gercek indirmeyi baslatir ve oneriyi tuketir
//   6. "Hepsini indir" tum onerileri indirir; zararli dosya adi kacislanir
//   7. Escape gorev gorunumune doner
//
// DIKKAT: kullanicinin AppData\Serene\captures.json dosyasi silinir ve indirme
// klasorunde yalnizca `panel-` onekli test ciktilari temizlenir.
//
// Kullanim: node scripts/check_panel.mjs

import { execSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { connect as netConnect } from "node:net";
import { createServer } from "node:http";

const EXE = "C:\\Users\\izzet\\Desktop\\serene\\src-tauri\\target\\debug\\serene.exe";
const CWD = "C:\\Users\\izzet\\Desktop\\serene\\src-tauri";
const ARTIFACTS = "C:\\Users\\izzet\\Desktop\\serene\\artifacts";
const IPC_PATH = join(process.env.APPDATA, "Serene", "ipc.json");
const CAPTURES_PATH = join(process.env.APPDATA, "Serene", "captures.json");
const PORT = Number(process.env.SERENE_CDP_PORT || 9339);
const HTTP_PORT = 8799;

/// Test ciktilari indirme klasorune bu onekle duser; temizlikte yalnizca bu
/// kalip silinir (kullanicinin kendi indirmelerine dokunulmaz).
const OUTPUT_PATTERN = /^panel-/;

const HOSTILE_NAME = `<img src=x onerror="document.title='xss'">`;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/* ---------- yerel test sunucusu ---------- */

const FILE_PAYLOAD = Buffer.alloc(64 * 1024, 0x6b);
const ts = (fill) => Buffer.alloc(6 * 1024, fill);
const HLS_SEGMENTS = [ts(0x51), ts(0x52)];
const PLAYLIST = `#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
seg0.ts
#EXTINF:4.0,
seg1.ts
#EXT-X-ENDLIST
`;

/// Medya dosyasi + iki parcali HLS akisi sunar. Aralik destegi probe'un
/// `Range: bytes=0-0` istegini 206 ile yanitlamasi icin sart.
function startHttpServer() {
  const routes = new Map();
  routes.set("/panel-medya.mp4", {
    type: "video/mp4",
    filename: "panel-medya.mp4",
    body: FILE_PAYLOAD,
  });
  routes.set("/video/index.m3u8", {
    type: "application/vnd.apple.mpegurl",
    filename: "panel-akis.ts",
    body: Buffer.from(PLAYLIST, "utf8"),
  });
  HLS_SEGMENTS.forEach((body, i) =>
    routes.set(`/video/seg${i}.ts`, { type: "video/mp2t", body })
  );

  const server = createServer((req, res) => {
    let entry = null;
    try {
      entry = routes.get(new URL(req.url, "http://127.0.0.1").pathname);
    } catch {
      entry = null;
    }
    if (!entry) {
      res.writeHead(404);
      res.end();
      return;
    }

    const total = entry.body.length;
    const headers = { "Content-Type": entry.type, "Accept-Ranges": "bytes" };
    if (entry.filename) {
      headers["Content-Disposition"] = `attachment; filename="${entry.filename}"`;
    }

    const range = req.headers.range;
    if (range) {
      const match = /bytes=(\d+)-(\d*)/.exec(range);
      const start = Number(match[1]);
      const end = match[2] ? Number(match[2]) : total - 1;
      res.writeHead(206, {
        ...headers,
        "Content-Length": end - start + 1,
        "Content-Range": `bytes ${start}-${end}/${total}`,
      });
      res.end(entry.body.subarray(start, end + 1));
      return;
    }

    res.writeHead(200, { ...headers, "Content-Length": total });
    res.end(entry.body);
  });

  return new Promise((resolve) => server.listen(HTTP_PORT, "127.0.0.1", () => resolve(server)));
}

/* ---------- CDP ---------- */

async function findTarget(timeoutMs = 40000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      const targets = await response.json();
      const page = targets.find((item) => item.type === "page" && item.webSocketDebuggerUrl);
      if (page) return page;
    } catch {
      /* port henuz acilmadi */
    }
    await sleep(500);
  }
  throw new Error(`CDP hedefi bulunamadi (port ${PORT})`);
}

class Cdp {
  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
  }

  send(method, params = {}) {
    const id = this.nextId++;
    this.socket.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`${method} zaman asimi`));
      }, 30000);
    });
  }

  handle(message) {
    const entry = this.pending.get(message.id);
    if (!entry) return;
    this.pending.delete(message.id);
    if (message.error) entry.reject(new Error(JSON.stringify(message.error)));
    else entry.resolve(message.result);
  }

  async evaluate(expression, awaitPromise = false) {
    const result = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise,
      returnByValue: true,
      userGesture: true,
    });
    if (result.exceptionDetails) {
      throw new Error(
        `JS hatasi: ${
          result.exceptionDetails.exception?.description || result.exceptionDetails.text
        }`
      );
    }
    return result.result.value;
  }

  close() {
    try {
      this.socket.close();
    } catch {
      /* kapali */
    }
  }
}

async function connectCdp() {
  const target = await findTarget();
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
  const cdp = new Cdp(socket);
  socket.addEventListener("message", (event) => cdp.handle(JSON.parse(event.data)));
  await cdp.send("Runtime.enable");
  return cdp;
}

async function waitForApp(cdp, timeoutMs = 25000) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    try {
      last = await cdp.evaluate(
        `(() => ({
          hasInput: Boolean(document.getElementById("url-input")),
          hasTauri: Boolean(window.__TAURI__ && window.__TAURI__.core),
        }))()`
      );
    } catch (error) {
      last = { error: error.message };
    }
    if (last && last.hasInput && last.hasTauri) return last;
    await sleep(300);
  }
  throw new Error(`arayuz hazir olmadi: ${JSON.stringify(last)}`);
}

/// Tauri komutunu arayuz uzerinden cagirir.
async function invoke(cdp, command, args = {}) {
  return cdp.evaluate(
    `(async () => await window.__TAURI__.core.invoke(${JSON.stringify(
      command
    )}, ${JSON.stringify(args)}))()`,
    true
  );
}

/// Panelin gorunur durumunu tek seferde okur.
const SNAPSHOT = `(() => {
  const text = (id) => {
    const node = document.getElementById(id);
    return node ? node.textContent.replace(/\\s+/g, " ").trim() : null;
  };
  const root = document.getElementById("task-root");
  const nav = document.getElementById("browser-queue");
  const count = document.querySelector("[data-count-captures]");
  const dot = document.getElementById("bridge-dot");
  return {
    hasNav: Boolean(document.getElementById("browser-nav")),
    active: nav ? nav.classList.contains("is-active") : null,
    count: count ? count.textContent.trim() : null,
    bridgeText: text("bridge-text"),
    dotClass: dot ? dot.className : null,
    rootText: root ? root.textContent.replace(/\\s+/g, " ").trim() : null,
    // Kart basina iki dugme var (Yoksay + Indir); oneri sayisi kimlikten sayilir.
    cards: root
      ? new Set(
          [...root.querySelectorAll("[data-capture][data-id]")].map((node) => node.dataset.id)
        ).size
      : 0,
    buttons: root ? root.querySelectorAll("[data-capture][data-id]").length : 0,
    hasBulk: Boolean(root && root.querySelector("[data-capture-all]")),
    images: root ? root.querySelectorAll("img").length : 0,
    toast: text("toast-root") || "",
    title: document.title,
  };
})()`;

function snapshot(cdp) {
  return cdp.evaluate(SNAPSHOT);
}

async function waitForSnapshot(cdp, predicate, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await snapshot(cdp);
    if (predicate(last)) return last;
    await sleep(300);
  }
  throw new Error(`${label} zaman asimi. Son durum: ${JSON.stringify(last)}`);
}

/* ---------- ham TCP istemcisi ---------- */

class IpcClient {
  constructor(socket) {
    this.socket = socket;
    this.buffer = "";
    this.messages = [];
    this.waiters = [];
    this.closed = false;

    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      this.buffer += chunk;
      let index;
      while ((index = this.buffer.indexOf("\n")) >= 0) {
        const line = this.buffer.slice(0, index).trim();
        this.buffer = this.buffer.slice(index + 1);
        if (!line) continue;
        let parsed;
        try {
          parsed = JSON.parse(line);
        } catch {
          continue;
        }
        this.messages.push(parsed);
        for (const waiter of [...this.waiters]) waiter(parsed);
      }
    });
    socket.on("close", () => (this.closed = true));
    socket.on("error", () => (this.closed = true));
  }

  send(object) {
    this.socket.write(`${JSON.stringify(object)}\n`);
  }

  waitFor(predicate, timeoutMs = 15000, label = "mesaj") {
    const found = this.messages.find(predicate);
    if (found) return Promise.resolve(found);

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== waiter);
        reject(
          new Error(`${label} zaman asimi. Gelenler: ${JSON.stringify(this.messages.slice(-3))}`)
        );
      }, timeoutMs);

      const waiter = (message) => {
        if (!predicate(message)) return;
        clearTimeout(timer);
        this.waiters = this.waiters.filter((w) => w !== waiter);
        resolve(message);
      };
      this.waiters.push(waiter);
    });
  }

  close() {
    try {
      this.socket.destroy();
    } catch {
      /* kapali */
    }
  }
}

async function openIpc(port) {
  const socket = netConnect({ host: "127.0.0.1", port });
  await new Promise((resolve, reject) => {
    socket.once("connect", resolve);
    socket.once("error", reject);
  });
  return new IpcClient(socket);
}

/* ---------- uygulama yasam dongusu ---------- */

function killSerene() {
  // Bayat bir ornek varsa tek ornek kilidi yuzunden yeni ornek hemen kapanir;
  // bu yuzden her kosu temiz bir surecle baslar.
  try {
    execSync('taskkill /F /IM serene.exe /T', { stdio: "ignore", windowsHide: true });
  } catch {
    /* calisan ornek yok */
  }
}

function spawnApp(env) {
  const proc = spawn(EXE, [], { cwd: CWD, env, stdio: ["ignore", "pipe", "pipe"] });
  const logs = [];
  proc.stdout.on("data", (chunk) => logs.push(chunk.toString()));
  proc.stderr.on("data", (chunk) => logs.push(chunk.toString()));
  return { proc, logs };
}

async function waitForIpc(timeoutMs = 25000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(IPC_PATH)) {
      try {
        const info = JSON.parse(readFileSync(IPC_PATH, "utf8"));
        if (info.port && info.token) return info;
      } catch {
        /* yazim suruyor */
      }
    }
    await sleep(300);
  }
  throw new Error("ipc.json olusmadi");
}

/// El sikismasini tamamlar ve abonelik kurar.
async function connectBridge(info) {
  const deadline = Date.now() + 15000;
  let client = null;
  while (Date.now() < deadline) {
    try {
      client = await openIpc(info.port);
      break;
    } catch {
      await sleep(300);
    }
  }
  if (!client) throw new Error(`kopruye baglanilamadi (port ${info.port})`);

  client.send({ type: "hello", token: info.token });
  await client.waitFor((m) => m.type === "ready", 10000, "ready");
  client.send({ type: "subscribe" });
  await client.waitFor((m) => m.type === "subscribed", 8000, "subscribed");
  return client;
}

/* ---------- yardimcilar ---------- */

function cleanDownloads(dir) {
  try {
    for (const name of readdirSync(dir)) {
      if (OUTPUT_PATTERN.test(name)) rmSync(join(dir, name), { force: true });
    }
  } catch {
    /* klasor yok */
  }
}

/// Eklenti gibi yakalama bildirir ve ack'i bekler.
async function reportCapture(client, reqId, payload) {
  client.send({ type: "capture", reqId, ...payload });
  const ack = await client.waitFor(
    (m) => (m.type === "ack" || m.type === "error") && m.reqId === reqId,
    15000,
    `capture ${reqId}`
  );
  if (ack.type === "error") throw new Error(`capture ${reqId}: ${ack.payload?.message}`);
  return ack.payload;
}

async function readTasks(cdp) {
  return invoke(cdp, "list_tasks");
}

/// Verilen url'ler icin yeni gorevlerin bitmesini bekler.
async function waitForTasks(cdp, urls, known, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  let last = [];
  while (Date.now() < deadline) {
    const tasks = await readTasks(cdp);
    last = tasks.filter((t) => !known.has(t.id) && urls.includes(t.url));
    const done = last.filter((t) => t.status === "completed");
    const failed = last.filter((t) => t.status === "failed");
    if (failed.length) {
      throw new Error(`${label}: indirme basarisiz (${failed[0].error})`);
    }
    if (last.length === urls.length && done.length === urls.length) return last;
    await sleep(400);
  }
  throw new Error(
    `${label}: gorevler bitmedi (${last.map((t) => `${t.url}=${t.status}`).join(", ")})`
  );
}

/* ---------- ana akis ---------- */

async function main() {
  const report = {};
  const problems = [];
  const check = (condition, message) => {
    if (!condition) problems.push(message);
  };

  mkdirSync(ARTIFACTS, { recursive: true });
  killSerene();
  await sleep(500);
  for (const path of [IPC_PATH, CAPTURES_PATH]) {
    try {
      rmSync(path, { force: true });
    } catch {
      /* yok */
    }
  }

  const httpServer = await startHttpServer();
  const env = { ...process.env };
  env.WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = `--remote-debugging-port=${PORT}`;

  console.log(`baslatiliyor: ${EXE}`);
  const app = spawnApp(env);
  let cdp = null;
  let client = null;
  let failed = false;

  try {
    const info = await waitForIpc();
    report.ipcPort = info.port;
    cdp = await connectCdp();
    await waitForApp(cdp);

    const settings = await invoke(cdp, "get_settings");
    const downloadsDir = settings.downloadDir;
    report.downloadsDir = downloadsDir;
    cleanDownloads(downloadsDir);

    /* 1. Statik iskelet ve baslangicta bos gorunum. */
    const initial = await snapshot(cdp);
    report.initial = initial;
    console.log(
      `iskelet: girdi=${initial.hasNav}, rozet=${initial.count}, gosterge=${JSON.stringify(
        initial.bridgeText
      )}`
    );
    check(initial.hasNav, "sol menude Tarayicidan girdisi yok");
    check(initial.count === "0", `rozet baslangicta 0 degil (${initial.count})`);
    check(initial.bridgeText === "Tarayıcı yok", `gosterge metni beklenen degil (${initial.bridgeText})`);
    check(
      (initial.dotClass || "").includes("bg-outline"),
      "gosterge kopru yokken gri degil"
    );

    /* 2. Girdiye tiklaninca yakalananlar gorunumu acilir. */
    await cdp.evaluate(`(() => { document.getElementById("browser-queue").click(); return true; })()`);
    const emptyView = await waitForSnapshot(
      cdp,
      (s) =>
        s.active &&
        s.cards === 0 &&
        (s.rootText || "").includes("Yakalananlar") &&
        (s.rootText || "").includes("Yakalanan medya yok"),
      6000,
      "bos yakalananlar gorunumu"
    );
    report.emptyView = { active: emptyView.active, text: emptyView.rootText };
    console.log(`bos gorunum: sekme vurgusu=${emptyView.active}`);
    check(!emptyView.hasBulk, "bos listede Hepsini indir butonu gorunur");

    /* 3. Kopruden istemci baglaninca gosterge yesile doner. */
    client = await connectBridge(info);
    const green = await waitForSnapshot(
      cdp,
      (s) => s.bridgeText === "Tarayıcı bağlı" && (s.dotClass || "").includes("bg-primary"),
      15000,
      "kopru gostergesi yesil"
    );
    report.bridgeGreen = { text: green.bridgeText, dot: green.dotClass };
    console.log(`kopru bagli: ${green.bridgeText}`);
    check(
      !(green.dotClass || "").includes("bg-outline"),
      "gosterge yesilken hala gri sinifi tasiyor"
    );

    /* 4. Yakalama gelince rozet, liste ve bildirim karti guncellenir. */
    const urlFile = `http://127.0.0.1:${HTTP_PORT}/panel-medya.mp4`;
    const urlHls = `http://127.0.0.1:${HTTP_PORT}/video/index.m3u8`;
    const first = await reportCapture(client, "p1", {
      url: urlFile,
      filename: "medya.mp4",
      size: FILE_PAYLOAD.length,
      contentType: "video/mp4",
      kind: "file",
      site: "127.0.0.1",
    });
    report.first = first;
    const listed = await waitForSnapshot(
      cdp,
      (s) => s.count === "1" && (s.rootText || "").includes("medya.mp4") && s.cards === 1,
      10000,
      "liste guncellemesi"
    );
    console.log(`yakalama listede: rozet=${listed.count}, kart=${listed.cards}`);
    check(!(listed.rootText || "").includes("Yakalanan medya yok"), "kayit geldigi halde bos durum yazisi duruyor");
    check(
      (listed.toast || "").includes("yakalandı"),
      `yeni yakalama bildirim karti cikmadi (${JSON.stringify(listed.toast.slice(0, 80))})`
    );
    // Bildirim karti sonraki tiklamalari kapatmasin diye kapatilir.
    await cdp.evaluate(`(() => { document.getElementById("toast-root").innerHTML = ""; return true; })()`);

    /* 5. Karttaki Indir gercek indirmeyi baslatir ve oneriyi tuketir. */
    let known = new Set((await readTasks(cdp)).map((t) => t.id));
    await cdp.evaluate(
      `(() => { document.querySelector('[data-capture="download"][data-id=${JSON.stringify(
        first.id
      )}]').click(); return true; })()`
    );
    const started = await waitForTasks(cdp, [urlFile], known, 60000, "kart indirmesi");
    report.cardDownload = started.map((t) => ({ url: t.url, status: t.status, total: t.total }));
    console.log(`kart indirmesi: ${started[0].status}, ${started[0].total} bayt`);
    const consumed = await waitForSnapshot(
      cdp,
      (s) => s.count === "0" && s.cards === 0,
      10000,
      "oneri tuketimi"
    );
    report.afterCardDownload = { count: consumed.count, text: consumed.rootText };
    check(
      (consumed.rootText || "").includes("Yakalanan medya yok"),
      "oneriler tukenince bos durum yazisi geri gelmedi"
    );

    /* 6. Zararli dosya adi kacislanir; Hepsini indir tum onerileri indirir. */
    await reportCapture(client, "p2", {
      url: urlHls,
      filename: "akis.m3u8",
      size: 0,
      contentType: "application/vnd.apple.mpegurl",
      kind: "hls",
      site: "127.0.0.1",
    });
    await reportCapture(client, "p3", {
      url: urlFile,
      filename: HOSTILE_NAME,
      size: FILE_PAYLOAD.length,
      contentType: "video/mp4",
      kind: "file",
      site: "127.0.0.1",
    });
    const two = await waitForSnapshot(
      cdp,
      (s) => s.count === "2" && s.cards === 2 && s.hasBulk,
      10000,
      "iki oneri"
    );
    report.twoItems = { count: two.count, cards: two.cards, hasBulk: two.hasBulk };
    console.log(`iki oneri: rozet=${two.count}, kart=${two.cards}, toplu buton=${two.hasBulk}`);
    check(two.images === 0, "zararli dosya adi DOM'a img dugumu enjekte etti (XSS)");
    check(two.title !== "xss", "zararli dosya adi sayfa basligini degistirdi (XSS)");
    check(
      (two.rootText || "").includes("<img"),
      "zararli dosya adi kacislanmis metin olarak gorunmuyor"
    );

    const shot = await cdp.send("Page.captureScreenshot", { format: "png" });
    const shotPath = join(ARTIFACTS, "serene-panel.png");
    writeFileSync(shotPath, Buffer.from(shot.data, "base64"));
    report.screenshot = shotPath;

    // Toplu indirme oncesi kimlikler yeniden alinir; kart indirmesinin gorevi
    // "yeni gorev" sayilip beklemeyi bozmasin.
    known = new Set((await readTasks(cdp)).map((t) => t.id));
    await cdp.evaluate(`(() => { document.querySelector("[data-capture-all]").click(); return true; })()`);
    const bulk = await waitForTasks(cdp, [urlFile, urlHls], known, 90000, "toplu indirme");
    report.bulk = bulk.map((t) => ({ url: t.url, status: t.status, total: t.total }));
    console.log(`toplu indirme: ${bulk.map((t) => `${t.total} bayt`).join(", ")}`);
    const drained = await waitForSnapshot(
      cdp,
      (s) => s.count === "0" && s.cards === 0,
      15000,
      "toplu tuketim"
    );
    report.afterBulk = { count: drained.count };
    console.log(`toplu indirme sonrasi rozet: ${drained.count}`);

    const onDisk = readdirSync(downloadsDir).filter((name) => OUTPUT_PATTERN.test(name));
    report.onDisk = onDisk;
    console.log(`diskteki test ciktilari: ${onDisk.join(", ") || "yok"}`);
    // Ayni url ikinci kez indirildigi icin diskte fazladan kopya olabilir;
    // aranan sey toplu indirmenin gercekten dosya birakmis olmasidir.
    check(
      onDisk.length >= bulk.length,
      `diskte ${onDisk.length} test dosyasi var (en az ${bulk.length} beklenirdi)`
    );
    check(!onDisk.some((name) => name.includes("<img")), "zararli ad dosya sistemine ulasti");

    /* 7. Escape gorev gorunumune doner. */
    await cdp.evaluate(
      `(() => { document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })); return true; })()`
    );
    const back = await waitForSnapshot(cdp, (s) => !s.active, 6000, "gorev gorunumu");
    report.backToTasks = { active: back.active, text: (back.rootText || "").slice(0, 60) };
    console.log(`Escape sonrasi sekme vurgusu: ${back.active}`);

    /* 8. Istemci ayrilinca gosterge griye duser. */
    client.close();
    client = null;
    const grey = await waitForSnapshot(
      cdp,
      (s) => s.bridgeText === "Tarayıcı yok" && (s.dotClass || "").includes("bg-outline"),
      20000,
      "gosterge gri"
    );
    report.bridgeGrey = grey.bridgeText;
    console.log(`istemci ayrildi: ${grey.bridgeText}`);

    /* Sonraki kosular temiz baslasin. */
    await invoke(cdp, "clear_captures");

    console.log("");
    console.log(JSON.stringify(report, null, 2));
    console.log("");
    if (problems.length) {
      failed = true;
      console.log(`BASARISIZ: ${problems.join("; ")}`);
    } else {
      console.log(
        "BASARILI: Tarayicidan girdisi, baglanti gostergesi, yakalama listesi, bildirim karti, tekli/toplu indirme ve kacis dogrulandi"
      );
    }
  } catch (error) {
    failed = true;
    console.log("");
    console.log(`BASARISIZ: ${error.message}`);
    try {
      if (cdp) {
        const shot = await cdp.send("Page.captureScreenshot", { format: "png" });
        writeFileSync(join(ARTIFACTS, "serene-panel.png"), Buffer.from(shot.data, "base64"));
      }
    } catch {
      /* ekran goruntusu alinamadi */
    }
  } finally {
    const log = app.logs.join("");
    if (log.trim()) {
      console.log("");
      console.log("--- uygulama cikisi ---");
      console.log(log.trim().slice(0, 4000));
    }
    if (client) client.close();
    if (cdp) cdp.close();
    killSerene();
    await sleep(800);
    cleanDownloads(join(process.env.USERPROFILE, "Downloads"));
    httpServer.close();
  }

  process.exit(failed ? 1 : 0);
}

main().catch((error) => {
  console.log(`beklenmeyen hata: ${error.message}`);
  process.exit(2);
});
