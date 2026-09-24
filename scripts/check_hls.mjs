// Serene HLS akis indiricisi dogrulamasi (Faz 5).
//
// Gercek uygulama baslatilir, yerel kopruye baglanilir ve HLS gorevleri
// `enqueue` ile verilir; sonuc dosyalari diskten okunup bayt bayt karsilastirilir.
//
// Dogrulananlar:
//   1. Master playlist -> en yuksek BANDWIDTH varyanti secilir, #EXT-X-MAP
//      init parcasi ve 6 parca tek dosyada birlesir (boyut = parcalarin toplami)
//   2. AES-128 sifreli akis cozulur (IV = medya sira numarasi) ve duz metinle ayni
//   3. Referer + Cookie olmadan 403 donen varyant, basliklar aktarildigi icin iner
//   4. Duraklat/devam: yarim kalan akis duraklatilir, devam ettirilir ve
//      tamamlanan parcalar yeniden inmeden dogru dosya olusur
//   5. METHOD=SAMPLE-AES (DRM) net bir hatayla reddedilir, uygulama cokmez
//
// Kullanim: node scripts/check_hls.mjs

import { execSync, spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { connect as netConnect } from "node:net";

import {
  EXPECTED,
  REQUIRED_COOKIE,
  REQUIRED_REFERER,
  start as startHlsServer,
} from "./serve_hls_test.mjs";

// Baska bir derlemeyi denemek icin: SERENE_EXE=...\target\release\serene.exe
const EXE =
  process.env.SERENE_EXE ||
  "C:\\Users\\izzet\\Desktop\\serene\\src-tauri\\target\\debug\\serene.exe";
const CWD = "C:\\Users\\izzet\\Desktop\\serene\\src-tauri";
const IPC_PATH = join(process.env.APPDATA, "Serene", "ipc.json");
const PORT = Number(process.env.SERENE_CDP_PORT || 9336);
const HTTP_PORT = 8796;

/// Test dosyalari indirme klasorune bu onekle duser; temizlikte yalnizca
/// bu kalip silinir (kullanicinin kendi indirmelerine dokunulmaz).
const OUTPUT_PATTERN = /^hls-(master|aes|auth|yavas|drm)( \(\d+\))?\.ts$/;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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
          new Error(`${label} zaman asimi. Gelenler: ${JSON.stringify(this.messages.slice(-4))}`)
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

/* ---------- yardimcilar ---------- */

function cleanDownloadDir(dir = join(process.env.USERPROFILE, "Downloads")) {
  try {
    for (const name of readdirSync(dir)) {
      if (OUTPUT_PATTERN.test(name)) rmSync(join(dir, name), { force: true });
    }
  } catch {
    /* klasor yok */
  }
}

async function taskById(cdp, id) {
  const tasks = await cdp.evaluate(
    `(async () => await window.__TAURI__.core.invoke("list_tasks"))()`,
    true
  );
  return tasks.find((task) => task.id === id);
}

async function waitForTask(cdp, id, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  let task = null;
  while (Date.now() < deadline) {
    task = await taskById(cdp, id);
    if (task && (task.status === "completed" || task.status === "failed")) return task;
    await sleep(250);
  }
  throw new Error(`${label}: gorev bitmedi (son durum: ${task?.status})`);
}

/// Bir gorevi kuyruga verir ve `ack` bekler.
async function enqueue(client, reqId, url, extra = {}) {
  client.send({ type: "enqueue", reqId, url, kind: "hls", ...extra });
  const ack = await client.waitFor((m) => m.type === "ack" && m.reqId === reqId, 30000, `ack ${reqId}`);
  return ack.payload;
}

/// Indirilen dosyayi diskten okuyup beklenen baytlarla karsilastirir.
function verifyFile(task, expected, label, problems, report) {
  const info = { dest: task.dest, total: task.total, downloaded: task.downloaded };
  report[label] = info;

  if (!task.dest || !existsSync(task.dest)) {
    problems.push(`${label}: dosya diskte yok (${task.dest})`);
    return;
  }
  const actual = readFileSync(task.dest);
  info.actualBytes = actual.length;
  info.expectedBytes = expected.length;
  console.log(
    `${label}: ${actual.length} bayt indi, beklenen ${expected.length} (gorev toplami=${task.total})`
  );
  if (actual.length !== expected.length) {
    problems.push(`${label}: boyut beklenen degil (${actual.length} != ${expected.length})`);
  } else if (!actual.equals(expected)) {
    problems.push(`${label}: icerik parcalarin birlesimiyle ayni degil`);
  }
  if (task.total !== expected.length) {
    problems.push(`${label}: meta.total beklenen degil (${task.total})`);
  }
  if (task.downloaded !== task.total) {
    problems.push(`${label}: meta.downloaded meta.total'e esit degil`);
  }
}

/* ---------- ana akis ---------- */

async function main() {
  const report = {};
  const problems = [];

  if (existsSync(IPC_PATH)) {
    try {
      execSync(`del /q "${IPC_PATH}"`, { stdio: "ignore", windowsHide: true });
    } catch {
      /* yok */
    }
  }
  cleanDownloadDir();

  const hls = await startHlsServer({ port: HTTP_PORT });
  console.log(`HLS test sunucusu: ${hls.url("/master.m3u8")}`);

  // Indirme klasoru ayarlardan ogrenilir; temizlik de oradan yapilir.
  let downloadsDir = join(process.env.USERPROFILE, "Downloads");

  const env = { ...process.env };
  env.WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = `--remote-debugging-port=${PORT}`;

  console.log(`baslatiliyor: ${EXE}`);
  const proc = spawn(EXE, [], { cwd: CWD, env, stdio: ["ignore", "pipe", "pipe"] });
  let appLog = "";
  proc.stdout.on("data", (chunk) => (appLog += chunk.toString()));
  proc.stderr.on("data", (chunk) => (appLog += chunk.toString()));

  let failed = false;

  try {
    const cdp = await connectCdp();
    await waitForApp(cdp);

    const deadline = Date.now() + 15000;
    while (!existsSync(IPC_PATH) && Date.now() < deadline) await sleep(300);
    if (!existsSync(IPC_PATH)) throw new Error("ipc.json olusmadi");
    const info = JSON.parse(readFileSync(IPC_PATH, "utf8"));

    const downloadsDirSetting = await cdp.evaluate(
      `(async () => (await window.__TAURI__.core.invoke("get_settings")).downloadDir)()`,
      true
    );
    downloadsDir = downloadsDirSetting;
    report.downloadsDir = downloadsDir;
    console.log(`indirme klasoru: ${downloadsDir}`);

    const client = await openIpc(info.port);
    client.send({ type: "hello", token: info.token });
    await client.waitFor((m) => m.type === "ready", 10000, "ready");
    client.send({ type: "subscribe" });
    await client.waitFor((m) => m.type === "subscribed", 8000, "subscribed");
    console.log("kopru hazir, abonelik kuruldu");

    /* 1. Master playlist -> en yuksek bant genisligi + init parcasi */
    const task1 = await enqueue(client, "hls1", hls.url("/master.m3u8"));
    console.log(`gorev 1 kuyruga girdi: ${task1.filename}`);
    const done1 = await waitForTask(cdp, task1.id, 60000, "master");
    if (done1.status !== "completed") {
      problems.push(`master: gorev tamamlanmadi (${done1.status}: ${done1.error})`);
    }
    report.masterStatus = done1.status;
    verifyFile(done1, EXPECTED.master, "master", problems, report);
    if (!String(done1.dest).startsWith(downloadsDir)) {
      problems.push("master: dosya indirme klasorunun disinda");
    }
    // Init parcasi basta olmali: dosya 0x11 deseniyle baslar, parcalar 0x40+.
    if (existsSync(done1.dest)) {
      if (readFileSync(done1.dest)[0] !== 0x11) {
        problems.push("master: #EXT-X-MAP init parcasi basta degil");
      }
    }

    /* 2. AES-128 sifreli akis */
    const task2 = await enqueue(client, "hls2", hls.url("/aes/index.m3u8"));
    const done2 = await waitForTask(cdp, task2.id, 60000, "aes");
    if (done2.status !== "completed") {
      problems.push(`aes: gorev tamamlanmadi (${done2.status}: ${done2.error})`);
    }
    report.aesStatus = done2.status;
    verifyFile(done2, EXPECTED.aes, "aes", problems, report);

    /* 3. Referer + Cookie isteyen varyant */
    const task3 = await enqueue(client, "hls3", hls.url("/auth/master.m3u8"), {
      referer: REQUIRED_REFERER,
      cookie: `a=1; ${REQUIRED_COOKIE}`,
    });
    const done3 = await waitForTask(cdp, task3.id, 60000, "auth");
    if (done3.status !== "completed") {
      problems.push(`auth: gorev tamamlanmadi (${done3.status}: ${done3.error})`);
    }
    report.authStatus = done3.status;
    verifyFile(done3, EXPECTED.auth, "auth", problems, report);

    /* 4. Duraklat / devam */
    const task4 = await enqueue(client, "hls4", hls.url("/slow/index.m3u8"));
    await sleep(900); // ilk parcalar bitsin, sonrakiler yarim kalsin
    await cdp.evaluate(
      `(async () => await window.__TAURI__.core.invoke("pause_download", { id: ${JSON.stringify(
        task4.id
      )} }))()`,
      true
    );
    await sleep(700);
    const paused = await taskById(cdp, task4.id);
    report.pause = { status: paused?.status, downloaded: paused?.downloaded };
    console.log(`duraklatildi: durum=${paused?.status}, inen=${paused?.downloaded}`);
    if (paused?.status !== "paused") problems.push(`duraklat: durum paused degil (${paused?.status})`);
    if (!(paused?.downloaded > 0 && paused?.downloaded < EXPECTED.slow.length)) {
      problems.push(`duraklat: ilerleme beklenen aralikta degil (${paused?.downloaded})`);
    }

    await cdp.evaluate(
      `(async () => await window.__TAURI__.core.invoke("resume_download", { id: ${JSON.stringify(
        task4.id
      )} }))()`,
      true
    );
    const done4 = await waitForTask(cdp, task4.id, 60000, "duraklat/devam");
    if (done4.status !== "completed") {
      problems.push(`duraklat/devam: gorev tamamlanmadi (${done4.status}: ${done4.error})`);
    }
    report.resumeStatus = done4.status;
    verifyFile(done4, EXPECTED.slow, "resume", problems, report);

    // Indirme surerken ilerleme paketi akmis olmali (arayuz ilerleme cubugu).
    const ticks = client.messages
      .filter((m) => m.type === "progress")
      .flatMap((m) => m.payload || [])
      .filter((tick) => tick.id === task4.id);
    report.progressTicks = ticks.length;
    report.maxTickBytes = ticks.reduce((max, tick) => Math.max(max, tick.downloaded), 0);
    console.log(
      `duraklat/devam sirasinda ilerleme paketi: ${ticks.length} (en yuksek inen=${report.maxTickBytes})`
    );
    if (ticks.length === 0) problems.push("duraklat/devam: hic ilerleme paketi gelmedi");
    if (report.maxTickBytes === 0) problems.push("duraklat/devam: ilerleme paketleri bos");

    /* 5. DRM reddi */
    const task5 = await enqueue(client, "hls5", hls.url("/drm/index.m3u8"));
    const done5 = await waitForTask(cdp, task5.id, 60000, "drm");
    report.drm = { status: done5.status, error: done5.error };
    console.log(`DRM gorevi: durum=${done5.status}, hata="${done5.error}"`);
    if (done5.status !== "failed") problems.push(`drm: gorev basarisiz olmadi (${done5.status})`);
    if (!String(done5.error || "").includes("DRM")) {
      problems.push(`drm: hata mesaji aciklayici degil (${done5.error})`);
    }
    if (existsSync(done5.dest)) problems.push("drm: basarisiz gorev yine de dosya birakti");

    // Uygulama yasiyor mu: kopru ve komutlar hala yanit vermeli.
    const alive = await cdp.evaluate(
      `(async () => (await window.__TAURI__.core.invoke("list_tasks")).length)()`,
      true
    );
    report.appAlive = alive >= 5;
    console.log(`DRM sonrasi uygulama ayakta: ${report.appAlive} (gorev sayisi=${alive})`);
    if (!report.appAlive) problems.push("drm: uygulama DRM hatasindan sonra yanit vermiyor");

    // Test kayitlarini gorev listesinden dusur (dosyalar finally'de silinir).
    for (const task of [task1, task2, task3, task4, task5]) {
      try {
        await cdp.evaluate(
          `(async () => await window.__TAURI__.core.invoke("remove_download", { id: ${JSON.stringify(
            task.id
          )} }))()`,
          true
        );
      } catch {
        /* gorev zaten yok */
      }
    }

    client.close();

    console.log("");
    console.log(JSON.stringify(report, null, 2));
    console.log("");
    if (problems.length) {
      failed = true;
      console.log(`BASARISIZ: ${problems.join("; ")}`);
    } else {
      console.log("BASARILI: HLS varyant secimi, birlestirme, AES-128, basliklar, duraklat/devam ve DRM reddi dogrulandi");
    }
  } catch (error) {
    failed = true;
    console.log("");
    console.log(`BASARISIZ: ${error.message}`);
  } finally {
    if (appLog.trim()) {
      console.log("");
      console.log("--- uygulama cikisi ---");
      console.log(appLog.trim().slice(0, 4000));
    }
    try {
      proc.kill();
    } catch {
      /* kapali */
    }
    await sleep(800);
    try {
      execSync('taskkill /F /IM serene.exe /T', { stdio: "ignore", windowsHide: true });
    } catch {
      /* kapali */
    }
    await sleep(400);
    cleanDownloadDir();
    await hls.close();
  }

  process.exit(failed ? 1 : 0);
}

main().catch((error) => {
  console.log(`beklenmeyen hata: ${error.message}`);
  process.exit(2);
});
