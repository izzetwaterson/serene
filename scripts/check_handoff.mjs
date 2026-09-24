// Serene "Indirme Bilgileri" penceresi dogrulamasi.
//
// Tarayicidan devralinan indirmeler (source: "download"/"menu") kullanici
// onaylayana kadar baslamaz; bu kosum gercek uygulamayi CDP ile surerek
// pencerenin acildigini, klasor/dosya adi degisikliginin uygulandigini ve
// uc kararin (Indirmeyi Baslat / Sonra Indir / Iptal) dogru sonucu verdigini
// kanitlar. Medya yakalamalari ve kaynaksiz enqueue'larin beklemedigi de
// ayni kosumda dogrulanir.
//
// Dogrulananlar:
//   1. Ayarlardaki "Tarayici indirmelerini once sor" anahtari kayitli degeri
//      yansitir ve kaydedildiginde diske yazilir
//   2. source=download gelen indirme `pending` dogar, pencere boyut/kategori/
//      adres ile acilir, gorev baslamaz
//   3. Pencerede klasor + dosya adi degistirilip "Indirmeyi Baslat" denince
//      dosya yeni adla yeni klasore iner
//   4. "Sonra Indir" gorevi onaylanmis ama duraklatilmis birakir; karttaki
//      "Devam Et" ile indirme tamamlanir
//   5. Kapatma (X / Escape) gorevi onay beklemeye birakir, listedeki
//      "Bilgileri Ac" pencereyi geri getirir, "Iptal" gorevi siler
//   6. source=capture bekletilmez, pencere hic acilmaz
//   7. Ayni anda gelen iki devralma siraya girer ("1 sirada" rozeti)
//
// DIKKAT: kosum sirasinda `%APPDATA%\Serene\tasks.json` gecici olarak
// silinir; baslamadan once `tasks.json.handoff-backup` olarak yedeklenir ve
// kosum sonunda geri konur. Indirme klasorunde yalnizca `handoff-` onekli
// test ciktilari temizlenir. Ayarlardaki onay anahtari kosum sonunda eski
// degerine dondurulur.
//
// Kullanim: node scripts/check_handoff.mjs
//   Baska bir derlemeyi denemek icin: SERENE_EXE=...\target\release\serene.exe

import { execSync, spawn } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { connect as netConnect } from "node:net";
import { createServer } from "node:http";

// Baska bir derlemeyi denemek icin: SERENE_EXE=...\target\release\serene.exe
const EXE =
  process.env.SERENE_EXE ||
  "C:\\Users\\izzet\\Desktop\\serene\\src-tauri\\target\\debug\\serene.exe";
const CWD = "C:\\Users\\izzet\\Desktop\\serene\\src-tauri";
const ARTIFACTS = "C:\\Users\\izzet\\Desktop\\serene\\artifacts";
const DATA_DIR = join(process.env.APPDATA, "Serene");
const IPC_PATH = join(DATA_DIR, "ipc.json");
const TASKS_PATH = join(DATA_DIR, "tasks.json");
const TASKS_BACKUP = `${TASKS_PATH}.handoff-backup`;
const PORT = Number(process.env.SERENE_CDP_PORT || 9341);
const HTTP_PORT = 8801;

/// Test ciktilari indirme klasorune bu onekle duser; temizlikte yalnizca bu
/// kalip silinir (kullanicinin kendi indirmelerine dokunulmaz).
const OUTPUT_PATTERN = /^handoff-/;
/// Klasor degistirme adiminda kullanilan alt klasor adi.
const ALT_DIR_NAME = "handoff-alt";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/* ---------- yerel test sunucusu ---------- */

const PDF_SIZE = 48 * 1024;
const ZIP_SIZE = 32 * 1024;
const LOOSE_SIZE = 16 * 1024;
const QUEUE_SIZE = 12 * 1024;

/// Aralik destegi sunan duz dosyalar (probe `Range: bytes=0-0` ile boyut
/// ogrenir; Content-Disposition dosya adini belirler).
function startHttpServer() {
  const routes = new Map();
  const file = (name, size, type) =>
    routes.set(`/${name}`, { type, filename: name, body: Buffer.alloc(size, 0x62) });

  file("handoff-rapor.pdf", PDF_SIZE, "application/pdf");
  file("handoff-paket.zip", ZIP_SIZE, "application/zip");
  file("handoff-duz.bin", LOOSE_SIZE, "application/octet-stream");
  file("handoff-kuyruk-a.bin", QUEUE_SIZE, "application/octet-stream");
  file("handoff-kuyruk-b.bin", QUEUE_SIZE, "application/octet-stream");
  file("handoff-serbest.bin", LOOSE_SIZE, "application/octet-stream");

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
    const headers = {
      "Content-Type": entry.type,
      "Accept-Ranges": "bytes",
      "Content-Disposition": `attachment; filename="${entry.filename}"`,
    };

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

const urlOf = (name) => `http://127.0.0.1:${HTTP_PORT}/${name}`;

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
      }, 45000);
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

/// `waitForApp` yalnizca belgenin ayristirildigini gosterir; `init()` hala
/// calisiyorsa tiklamalar sessizce dusebilir. Ayarlar penceresini acip
/// kapatarak olay baglamalarinin kuruldugunu dogrulariz.
async function waitForBindings(cdp, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await cdp.evaluate(`(() => {
      document.getElementById("open-settings").click();
      const open = !document.getElementById("settings-modal").classList.contains("hidden");
      if (open) document.getElementById("close-settings").click();
      return { open, hint: document.getElementById("dest-hint-text").textContent.trim() };
    })()`);
    if (last.open) return last;
    await sleep(250);
  }
  throw new Error(`arayuz baglamalari kurulmadi: ${JSON.stringify(last)}`);
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

/// Pencerenin ve gorev listesinin gorunur durumunu tek seferde okur.
const SNAPSHOT = `(() => {
  const text = (id) => {
    const node = document.getElementById(id);
    return node ? node.textContent.replace(/\\s+/g, " ").trim() : null;
  };
  const value = (id) => {
    const node = document.getElementById(id);
    return node ? node.value : null;
  };
  const modal = document.getElementById("handoff-modal");
  const count = document.getElementById("handoff-count");
  const root = document.getElementById("task-root");
  return {
    open: Boolean(modal && !modal.classList.contains("hidden")),
    filename: value("handoff-filename"),
    url: value("handoff-url"),
    dir: value("handoff-dir"),
    category: text("handoff-cat"),
    size: text("handoff-size"),
    note: text("handoff-note"),
    badge: count && !count.classList.contains("hidden") ? count.textContent.trim() : null,
    listText: root ? root.textContent.replace(/\\s+/g, " ").trim() : "",
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
    await sleep(250);
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

/// Test ciktilari indirme klasorune bu onekle duser; temizlikte yalnizca bu
/// kalip silinir (kullanicinin kendi indirmelerine dokunulmaz). Alt klasor de
/// ayni kalibi tasir, bu yuzden dizinler de temizlenir.
function cleanOutputs(dir) {
  try {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (!OUTPUT_PATTERN.test(entry.name)) continue;
      rmSync(join(dir, entry.name), {
        force: true,
        recursive: entry.isDirectory(),
      });
    }
  } catch {
    /* klasor yok */
  }
}

/// Yalnizca dosyalar sayilir; `handoff-alt` gibi test klasorleri liste disi.
function outputsIn(dir) {
  try {
    return readdirSync(dir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && OUTPUT_PATTERN.test(entry.name))
      .map((entry) => entry.name);
  } catch {
    return [];
  }
}

/// Eklenti gibi devralma bildirir ve ack'i bekler.
async function handOff(client, reqId, payload) {
  client.send({ type: "enqueue", reqId, ...payload });
  const ack = await client.waitFor(
    (m) => (m.type === "ack" || m.type === "error") && m.reqId === reqId,
    20000,
    `enqueue ${reqId}`
  );
  if (ack.type === "error") throw new Error(`enqueue ${reqId}: ${ack.payload?.message}`);
  return ack.payload;
}

const byUrl = (tasks, url) => tasks.filter((t) => t.url === url);

/// Gorev verilen duruma gelene kadar bekler (en yeni kayit secilir).
async function waitForTask(cdp, url, predicate, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    const tasks = await invoke(cdp, "list_tasks");
    const mine = byUrl(tasks, url);
    last = mine.length ? mine[mine.length - 1] : null;
    if (last && predicate(last)) return last;
    await sleep(250);
  }
  throw new Error(`${label} zaman asimi. Son durum: ${JSON.stringify(last)}`);
}

async function waitForGone(cdp, url, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    const tasks = await invoke(cdp, "list_tasks");
    last = byUrl(tasks, url);
    if (!last.length) return;
    await sleep(250);
  }
  throw new Error(`${label} zaman asimi. Kalan: ${JSON.stringify(last.map((t) => t.id))}`);
}

const clickSelector = (selector) =>
  `(() => { const node = document.querySelector(${JSON.stringify(
    selector
  )}); if (!node) return false; node.click(); return true; })()`;

const setValue = (id, value) =>
  `(() => { document.getElementById(${JSON.stringify(
    id
  )}).value = ${JSON.stringify(value)}; return true; })()`;

/* ---------- ana akis ---------- */

async function main() {
  const report = {};
  const problems = [];
  const check = (condition, message) => {
    if (!condition) problems.push(message);
  };

  mkdirSync(ARTIFACTS, { recursive: true });
  mkdirSync(DATA_DIR, { recursive: true });
  killSerene();
  await sleep(500);

  // Onceki oturumdan kalan ipc.json bayat port tasir; bekleme dongusu onu
  // taze sanip yanlis porta baglanmaya calisirdi.
  try {
    rmSync(IPC_PATH, { force: true });
  } catch {
    /* yok */
  }

  // Gorev listesi yedeklenip temizlenir: onceki oturumdan kalan "onay bekleyen"
  // bir kayit pencerenin ilk halini belirsizlestirirdi.
  let restoreTasks = false;
  try {
    rmSync(TASKS_BACKUP, { force: true });
    if (existsSync(TASKS_PATH)) {
      renameSync(TASKS_PATH, TASKS_BACKUP);
      restoreTasks = true;
    }
    rmSync(TASKS_PATH, { force: true });
  } catch (error) {
    console.log(`uyari: tasks.json yedeklenemedi (${error.message})`);
  }

  const httpServer = await startHttpServer();
  const env = { ...process.env };
  env.WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = `--remote-debugging-port=${PORT}`;

  console.log(`baslatiliyor: ${EXE}`);
  const app = spawnApp(env);
  let cdp = null;
  let client = null;
  let settingsBefore = null;
  let failed = false;

  try {
    const info = await waitForIpc();
    report.ipcPort = info.port;
    cdp = await connectCdp();
    await waitForApp(cdp);
    await waitForBindings(cdp);

    settingsBefore = await invoke(cdp, "get_settings");
    report.settingsBefore = { confirmBrowserDownload: settingsBefore.confirmBrowserDownload };
    const downloadsDir = settingsBefore.downloadDir;
    const altDir = join(downloadsDir, ALT_DIR_NAME);
    report.downloadsDir = downloadsDir;
    cleanOutputs(downloadsDir);
    mkdirSync(altDir, { recursive: true });
    cleanOutputs(altDir);

    /* 1. Ayarlardaki onay anahtari kayitli degeri yansitir ve yazar. */
    const wired = await cdp.evaluate(`(() => {
      document.getElementById("open-settings").click();
      return {
        checked: document.getElementById("set-confirm").checked,
        stored: null,
      };
    })()`);
    check(
      wired.checked === settingsBefore.confirmBrowserDownload,
      `onay anahtari kayitli degeri yansitmiyor (${wired.checked} != ${settingsBefore.confirmBrowserDownload})`
    );

    const toggle = await cdp.evaluate(
      `(async () => {
        const box = document.getElementById("set-confirm");
        const read = async () => (await window.__TAURI__.core.invoke("get_settings")).confirmBrowserDownload;
        box.checked = false;
        document.getElementById("save-settings").click();
        await new Promise((r) => setTimeout(r, 900));
        const off = await read();
        document.getElementById("open-settings").click();
        box.checked = true;
        document.getElementById("save-settings").click();
        await new Promise((r) => setTimeout(r, 900));
        const on = await read();
        return { off, on };
      })()`,
      true
    );
    report.toggle = toggle;
    console.log(`ayar anahtari: kapali=${toggle.off}, acik=${toggle.on}`);
    check(toggle.off === false, "anahtar kapatilinca ayar diske yazilmadi");
    check(toggle.on === true, "anahtar acilinca ayar diske yazilmadi");
    await cdp.evaluate(`(() => { document.getElementById("close-settings").click(); return true; })()`);

    const before = await snapshot(cdp);
    check(!before.open, "henuz indirme yokken pencere acik");

    /* 2. Kopruden devralinan indirme beklemede kalir ve pencere acilir. */
    client = await connectBridge(info);
    const urlPdf = urlOf("handoff-rapor.pdf");
    const task = await handOff(client, "h1", {
      url: urlPdf,
      source: "download",
      referer: `http://127.0.0.1:${HTTP_PORT}/indir`,
      cookie: "serene=test",
      userAgent: "HandoffTest/1.0",
    });
    report.enqueue = { id: task.id, status: task.status, pending: task.pending, total: task.total };

    const dialog = await waitForSnapshot(
      cdp,
      (s) => s.open && s.filename === "handoff-rapor.pdf",
      20000,
      "bilgi penceresi"
    );
    report.dialog = {
      filename: dialog.filename,
      url: dialog.url,
      dir: dialog.dir,
      category: dialog.category,
      size: dialog.size,
      note: dialog.note,
    };
    console.log(
      `pencere: ${dialog.filename} | ${dialog.category} | ${dialog.size} | ${JSON.stringify(
        dialog.dir
      )}`
    );
    check(dialog.url === urlPdf, `penceredeki adres beklenen degil (${dialog.url})`);
    check(dialog.category === "Belgeler", `kategori etiketi beklenen degil (${dialog.category})`);
    check(/\bbayt\b/.test(dialog.size || ""), `boyut satirinda bayt degeri yok (${dialog.size})`);
    check(
      (dialog.size || "").includes("48"),
      `boyut 48 KB olarak gosterilmedi (${dialog.size})`
    );
    check(
      dialog.dir === downloadsDir,
      `kayit klasoru ayardaki klasor degil (${dialog.dir} != ${downloadsDir})`
    );
    check(
      (dialog.note || "").includes("parçalı"),
      `parcali indirme notu yok (${dialog.note})`
    );
    check(
      (dialog.listText || "").includes("Onay bekliyor"),
      "kartta 'Onay bekliyor' rozeti yok"
    );

    const held = await waitForTask(
      cdp,
      urlPdf,
      (t) => t.pending === true && t.status === "paused",
      8000,
      "bekleyen gorev"
    );
    report.held = { status: held.status, pending: held.pending, downloaded: held.downloaded };
    console.log(`beklemede: durum=${held.status}, indirilen=${held.downloaded}`);
    check(held.downloaded === 0, `bekleyen gorev veri indirmis (${held.downloaded} bayt)`);
    check(
      outputsIn(downloadsDir).length === 0 && outputsIn(altDir).length === 0,
      "onay verilmeden diske dosya yazildi"
    );

    const shot = await cdp.send("Page.captureScreenshot", { format: "png" });
    const shotPath = join(ARTIFACTS, "serene-handoff.png");
    writeFileSync(shotPath, Buffer.from(shot.data, "base64"));
    report.screenshot = shotPath;

    /* 3. Klasor + dosya adi degistirilip indirme baslatilir. */
    await cdp.evaluate(setValue("handoff-dir", altDir));
    await cdp.evaluate(setValue("handoff-filename", "handoff-yeniden-adlandi.pdf"));
    await cdp.evaluate(clickSelector("#handoff-start"));

    const done = await waitForTask(
      cdp,
      urlPdf,
      (t) => t.status === "completed",
      60000,
      "baslatilan indirme"
    );
    const destName = done.dest.split(/[\\/]/).pop();
    report.started = { status: done.status, pending: done.pending, dest: done.dest };
    console.log(`indirildi: ${done.dest}`);
    check(done.pending === false, "onaydan sonra gorev hala beklemede");
    check(destName === "handoff-yeniden-adlandi.pdf", `dosya adi uygulanmadi (${destName})`);
    check(
      done.dest.startsWith(altDir),
      `klasor degisikligi uygulanmadi (${done.dest})`
    );
    check(
      Number(statSync(done.dest).size) === PDF_SIZE,
      "inen dosyanin boyutu beklenen degil"
    );
    const closed = await waitForSnapshot(cdp, (s) => !s.open, 8000, "pencere kapanmasi");
    check(!closed.open, "indirme basladiktan sonra pencere kapanmadi");

    /* 4. "Sonra Indir" onaylar ama baslatmaz; karttan devam edilebilir. */
    const urlZip = urlOf("handoff-paket.zip");
    await handOff(client, "h2", { url: urlZip, source: "menu" });
    const laterDialog = await waitForSnapshot(
      cdp,
      (s) => s.open && s.filename === "handoff-paket.zip",
      20000,
      "ikinci pencere"
    );
    check(
      laterDialog.category === "Sıkıştırılmış",
      `arsiv kategorisi beklenen degil (${laterDialog.category})`
    );
    await cdp.evaluate(clickSelector("#handoff-later"));
    const deferred = await waitForTask(
      cdp,
      urlZip,
      (t) => t.status === "paused" && t.pending === false,
      15000,
      "sonra indir"
    );
    report.deferred = { status: deferred.status, pending: deferred.pending };
    console.log(`sonra indir: durum=${deferred.status}, bekleme=${deferred.pending}`);
    check(deferred.downloaded === 0, "sonra indir denen gorev veri indirmis");
    const deferredView = await waitForSnapshot(cdp, (s) => !s.open, 8000, "pencere kapanmasi");
    check(
      (deferredView.listText || "").includes("Duraklatıldı"),
      "onaylanan gorev listede duraklatilmis gorunmuyor"
    );

    await cdp.evaluate(clickSelector(`[data-action="resume"][data-id="${deferred.id}"]`));
    const resumed = await waitForTask(
      cdp,
      urlZip,
      (t) => t.status === "completed",
      60000,
      "devam ettirilen indirme"
    );
    check(
      outputsIn(downloadsDir).includes("handoff-paket.zip"),
      "devam ettirilen dosya indirme klasorunde yok"
    );
    console.log(`devam ettirildi: ${resumed.dest}`);

    /* 5. Kapatma, yeniden acma ve iptal. */
    const urlLoose = urlOf("handoff-duz.bin");
    await handOff(client, "h3", { url: urlLoose, source: "download" });
    await waitForSnapshot(
      cdp,
      (s) => s.open && s.filename === "handoff-duz.bin",
      20000,
      "ucuncu pencere"
    );
    check(
      (await snapshot(cdp)).category === "Diğer",
      "bilinmeyen uzanti 'Diger' kategorisine dusmedi"
    );

    await cdp.evaluate(clickSelector("#close-handoff"));
    const afterClose = await waitForSnapshot(cdp, (s) => !s.open, 8000, "X ile kapatma");
    check(!afterClose.open, "X dugmesi pencereyi kapatmadi");
    const stillPending = await waitForTask(
      cdp,
      urlLoose,
      (t) => t.pending === true,
      8000,
      "kapatma sonrasi bekleme"
    );
    check(
      stillPending.status === "paused",
      `kapatilan gorev duraklatilmis kalmadi (${stillPending.status})`
    );
    check(
      (afterClose.listText || "").includes("Onay bekliyor"),
      "kapatilan gorev listede onay bekliyor olarak gorunmuyor"
    );

    await cdp.evaluate(clickSelector(`[data-action="info"][data-id="${stillPending.id}"]`));
    const reopened = await waitForSnapshot(
      cdp,
      (s) => s.open && s.filename === "handoff-duz.bin",
      10000,
      "yeniden acilan pencere"
    );
    check(reopened.open, "Bilgileri Ac dugmesi pencereyi geri getirmedi");

    // Escape de X gibi davranir: pencereyi kapatir, gorev beklemede kalir.
    await cdp.evaluate(
      `(() => { document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })); return true; })()`
    );
    const escaped = await waitForSnapshot(cdp, (s) => !s.open, 8000, "Escape ile kapatma");
    check(!escaped.open, "Escape pencereyi kapatmadi");
    await waitForTask(cdp, urlLoose, (t) => t.pending === true, 8000, "Escape sonrasi bekleme");

    await cdp.evaluate(clickSelector(`[data-action="info"][data-id="${stillPending.id}"]`));
    await waitForSnapshot(cdp, (s) => s.open, 10000, "ikinci kez acilan pencere");
    await cdp.evaluate(clickSelector("#handoff-cancel"));
    await waitForGone(cdp, urlLoose, 15000, "iptal edilen gorev");
    const afterCancel = await waitForSnapshot(cdp, (s) => !s.open, 8000, "iptal kapanmasi");
    check(!afterCancel.open, "Iptal pencereyi kapatmadi");
    check(
      !outputsIn(altDir).includes("handoff-duz.bin") &&
        !outputsIn(downloadsDir).includes("handoff-duz.bin"),
      "iptal edilen indirme diske dosya birakti"
    );
    console.log("iptal: gorev listeden ve pencereden dustu");

    /* 6. Medya yakalamasi (source=capture) beklemez. */
    const urlFree = urlOf("handoff-serbest.bin");
    const free = await handOff(client, "h4", { url: urlFree, source: "capture" });
    report.free = { status: free.status, pending: free.pending };
    check(free.pending === false, "yakalama kaynagi beklemede basladi");
    const freeOpen = await snapshot(cdp);
    check(!freeOpen.open, "yakalama kaynagi icin pencere acildi");
    await waitForTask(cdp, urlFree, (t) => t.status === "completed", 60000, "yakalama indirmesi");
    console.log("yakalama kaynagi beklemeden indi");

    /* 7. Ayni anda gelen iki devralma siraya girer. */
    const urlA = urlOf("handoff-kuyruk-a.bin");
    const urlB = urlOf("handoff-kuyruk-b.bin");
    await handOff(client, "h5", { url: urlA, source: "download" });
    await handOff(client, "h6", { url: urlB, source: "download" });
    const queued = await waitForSnapshot(cdp, (s) => s.open && s.badge, 20000, "sira rozeti");
    report.queue = { badge: queued.badge, first: queued.filename };
    console.log(`sirada: ${queued.badge}, pencerede: ${queued.filename}`);
    check(
      (queued.badge || "").includes("1 sırada"),
      `bekleyen ikinci gorev icin rozet cikmadi (${queued.badge})`
    );

    const shownFirst = queued.filename;
    const other = shownFirst === "handoff-kuyruk-a.bin" ? "handoff-kuyruk-b.bin" : "handoff-kuyruk-a.bin";
    await cdp.evaluate(clickSelector("#handoff-cancel"));
    const second = await waitForSnapshot(cdp, (s) => s.open && s.filename === other, 15000, "siradaki pencere");
    check(second.open, "ilk gorev iptal edilince siradaki gelmedi");
    check(second.badge === null, `son gorev gelince sira rozeti hala duruyor (${second.badge})`);
    console.log(`siradaki gorev acildi: ${second.filename}`);

    await cdp.evaluate(clickSelector("#handoff-cancel"));
    await waitForGone(cdp, urlA, 15000, "kuyruk gorevi a");
    await waitForGone(cdp, urlB, 15000, "kuyruk gorevi b");
    const empty = await waitForSnapshot(cdp, (s) => !s.open, 8000, "son kapanma");
    check(!empty.open, "son gorev iptal edilince pencere kapanmadi");

    /* Bekleyen kalmadi mi ve disk temiz mi? */
    const leftovers = (await invoke(cdp, "list_tasks")).filter((t) => t.pending);
    report.pendingLeft = leftovers.length;
    check(leftovers.length === 0, `koşum sonunda ${leftovers.length} gorev hala onay bekliyor`);
    const onDisk = [...outputsIn(downloadsDir), ...outputsIn(altDir)].sort();
    report.onDisk = onDisk;
    console.log(`diskteki test ciktilari: ${onDisk.join(", ") || "yok"}`);
    check(
      onDisk.length === 3 &&
        onDisk.includes("handoff-paket.zip") &&
        onDisk.includes("handoff-serbest.bin") &&
        onDisk.includes("handoff-yeniden-adlandi.pdf"),
      `disk beklenen ciktilari icermiyor (${onDisk.join(", ")})`
    );

    await invoke(cdp, "clear_completed");

    console.log("");
    console.log(JSON.stringify(report, null, 2));
    console.log("");
    if (problems.length) {
      failed = true;
      console.log(`BASARISIZ: ${problems.join("; ")}`);
    } else {
      console.log(
        "BASARILI: Bilgi penceresi, klasor/ad degisikligi, baslat/ertele/iptal kararlari, sira rozeti ve yakalama muafiyeti dogrulandi"
      );
    }
  } catch (error) {
    failed = true;
    console.log("");
    console.log(`BASARISIZ: ${error.message}`);
    try {
      if (cdp) {
        const shot = await cdp.send("Page.captureScreenshot", { format: "png" });
        writeFileSync(join(ARTIFACTS, "serene-handoff.png"), Buffer.from(shot.data, "base64"));
      }
    } catch {
      /* ekran goruntusu alinamadi */
    }
  } finally {
    // Ayar kosum oncesi degerine dondurulur; kullanici tercihi kalici olmasin.
    try {
      if (cdp && settingsBefore) {
        await invoke(cdp, "update_settings", {
          settings: {
            ...settingsBefore,
            confirmBrowserDownload: settingsBefore.confirmBrowserDownload,
          },
        });
      }
    } catch {
      /* ayar geri yazilamadi */
    }

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

    // Kullanici listesi geri konur (test kayitlari orada kalmasin).
    try {
      if (restoreTasks) {
        rmSync(TASKS_PATH, { force: true });
        renameSync(TASKS_BACKUP, TASKS_PATH);
        console.log("tasks.json yedekten geri kondu");
      }
    } catch (error) {
      console.log(`uyari: tasks.json geri konulamadi (${error.message})`);
    }

    cleanOutputs(join(process.env.USERPROFILE, "Downloads"));
    httpServer.close();
  }

  process.exit(failed ? 1 : 0);
}

main().catch((error) => {
  console.log(`beklenmeyen hata: ${error.message}`);
  process.exit(2);
});
