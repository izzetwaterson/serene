// Serene DASH akis indiricisi dogrulamasi (Faz 6).
//
// Gercek uygulama baslatilir, yerel kopruye baglanilir ve DASH gorevleri
// `enqueue` ile verilir; sonuc dosyalari diskten okunup bayt bayt karsilastirilir.
//
// Dogrulananlar:
//   1. SegmentTemplate + $Number$: video kumesi (en yuksek bandwidth) secilir,
//      init parcasi + 5 parca tek .mp4 dosyada birlesir (boyut = parcalarin toplami)
//   2. Ayri ses AdaptationSet'i inilmez: cikti yalnizca video parcalarindan olusur
//   3. SegmentTimeline + $Time$ + $RepresentationID$ sablonu acilir ve dogru sirada iner
//   4. SegmentBase indexRange (desteklenmeyen yapi) net bir hatayla reddedilir,
//      uygulama cokmez
//
// Kullanim: node scripts/check_dash.mjs

import { execSync, spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { connect as netConnect } from "node:net";

import { EXPECTED, start as startTestServer } from "./serve_hls_test.mjs";

const EXE = "C:\\Users\\izzet\\Desktop\\serene\\src-tauri\\target\\debug\\serene.exe";
const CWD = "C:\\Users\\izzet\\Desktop\\serene\\src-tauri";
const IPC_PATH = join(process.env.APPDATA, "Serene", "ipc.json");
const PORT = Number(process.env.SERENE_CDP_PORT || 9337);
// HLS betigi 8796'yi kullanir; iki betik arka arkaya kosarken cakismasin.
const HTTP_PORT = 8797;

/// Test dosyalari indirme klasorune bu onekle duser; temizlikte yalnizca
/// bu kalip silinir (kullanicinin kendi indirmelerine dokunulmaz).
const OUTPUT_PATTERN = /^dash-(template|timeline|broken)( \(\d+\))?\.mp4$/;

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

/// Bir gorevi kuyruga verir ve `ack` bekler. Tur acikca `dash` gonderilir.
async function enqueue(client, reqId, url) {
  client.send({ type: "enqueue", reqId, url, kind: "dash" });
  const ack = await client.waitFor(
    (m) => m.type === "ack" && m.reqId === reqId,
    30000,
    `ack ${reqId}`
  );
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
  // Cikti adi MPD'nin Content-Disposition'indan gelir; fMP4 icin .mp4 beklenir.
  if (!String(task.dest).toLowerCase().endsWith(".mp4")) {
    problems.push(`${label}: cikti dosyasi .mp4 degil (${task.dest})`);
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

  const server = await startTestServer({ port: HTTP_PORT });
  console.log(`DASH test sunucusu: ${server.url("/dash/manifest.mpd")}`);

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

    /* 1-2. SegmentTemplate + $Number$: video secilir, ayri ses inilmez */
    const task1 = await enqueue(client, "dash1", server.url("/dash/manifest.mpd"));
    console.log(`gorev 1 kuyruga girdi: ${task1.filename}`);
    const done1 = await waitForTask(cdp, task1.id, 60000, "template");
    if (done1.status !== "completed") {
      problems.push(`template: gorev tamamlanmadi (${done1.status}: ${done1.error})`);
    }
    report.templateStatus = done1.status;
    verifyFile(done1, EXPECTED.dash, "template", problems, report);
    if (!String(done1.dest).startsWith(downloadsDir)) {
      problems.push("template: dosya indirme klasorunun disinda");
    }
    // Init parcasi basta olmali: dosya 0x21 deseniyle baslar, parcalar 0x50+.
    if (existsSync(done1.dest)) {
      const head = readFileSync(done1.dest);
      if (head[0] !== 0x21) problems.push("template: init parcasi basta degil");
      if (head.includes(0x90)) problems.push("template: ayri ses parcasi ciktiya karismis");
    }

    /* 3. SegmentTimeline + $Time$ + $RepresentationID$ */
    const task2 = await enqueue(client, "dash2", server.url("/dash/timeline.mpd"));
    const done2 = await waitForTask(cdp, task2.id, 60000, "timeline");
    if (done2.status !== "completed") {
      problems.push(`timeline: gorev tamamlanmadi (${done2.status}: ${done2.error})`);
    }
    report.timelineStatus = done2.status;
    verifyFile(done2, EXPECTED.dashTimeline, "timeline", problems, report);

    /* 4. Desteklenmeyen yapi: SegmentBase indexRange */
    const task3 = await enqueue(client, "dash3", server.url("/dash/broken.mpd"));
    const done3 = await waitForTask(cdp, task3.id, 60000, "broken");
    report.broken = { status: done3.status, error: done3.error };
    console.log(`desteklenmeyen manifest: durum=${done3.status}, hata="${done3.error}"`);
    if (done3.status !== "failed") problems.push(`broken: gorev basarisiz olmadi (${done3.status})`);
    if (!String(done3.error || "").includes("indexRange")) {
      problems.push(`broken: hata mesaji aciklayici degil (${done3.error})`);
    }
    if (existsSync(done3.dest)) problems.push("broken: basarisiz gorev yine de dosya birakti");

    // Uygulama yasiyor mu: kopru ve komutlar hala yanit vermeli.
    const alive = await cdp.evaluate(
      `(async () => (await window.__TAURI__.core.invoke("list_tasks")).length)()`,
      true
    );
    report.appAlive = alive >= 3;
    console.log(`desteklenmeyen manifest sonrasi uygulama ayakta: ${report.appAlive}`);
    if (!report.appAlive) problems.push("broken: uygulama hatadan sonra yanit vermiyor");

    // Test kayitlarini gorev listesinden dusur (dosyalar finally'de silinir).
    for (const task of [task1, task2, task3]) {
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
      console.log(
        "BASARILI: DASH SegmentTemplate $Number$, SegmentTimeline $Time$, video secimi, ayri sesin dislanmasi ve desteklenmeyen yapinin reddi dogrulandi"
      );
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
    await server.close();
  }

  process.exit(failed ? 1 : 0);
}

main().catch((error) => {
  console.log(`beklenmeyen hata: ${error.message}`);
  process.exit(2);
});
