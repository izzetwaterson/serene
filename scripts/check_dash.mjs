// Serene DASH akis indiricisi dogrulamasi (Faz 6).
//
// Gercek uygulama baslatilir, yerel kopruye baglanilir ve DASH gorevleri
// `enqueue` ile verilir; sonuc dosyalari diskten okunup bayt bayt karsilastirilir.
// Webview surulmez: tum adimlar kopru protokolu uzerinden yurutulur.
//
// Dogrulananlar:
//   1. SegmentTemplate + $Number$: video kumesi (en yuksek bandwidth) secilir,
//      init parcasi + 5 parca tek .mp4 dosyada birlesir (boyut = parcalarin toplami)
//   2. Ayri ses AdaptationSet'i inilmez: cikti yalnizca video parcalarindan olusur
//   3. SegmentTimeline + $Time$ + $RepresentationID$ sablonu acilir ve dogru sirada iner
//   4. SegmentBase indexRange (desteklenmeyen yapi) net bir hatayla reddedilir,
//      uygulama cokmez
//
// Kullanim:
//   cd flutter_app && flutter build windows --debug
//   node scripts/check_dash.mjs
//
// Baska bir derlemeyi denemek icin: SERENE_APP_EXE=...\Serene.exe
// Her sey gecici bir klasorde yasar: kullanicinin %APPDATA%\Serene'i ve
// Indirilenler'i etkilenmez.

import { spawn, spawnSync, execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { connect as netConnect } from "node:net";

import { EXPECTED, start as startTestServer } from "./serve_hls_test.mjs";

const ROOT = resolve(import.meta.dirname, "..");
const EXE =
  process.env.SERENE_APP_EXE ||
  join(ROOT, "flutter_app", "build", "windows", "x64", "runner", "Debug", "Serene.exe");
const IMAGE = "Serene";
const LIST_WINDOWS = join(ROOT, "scripts", "list_windows.ps1");
// HLS betigi 8796'yi kullanir; iki betik arka arkaya kosarken cakismasin.
const HTTP_PORT = 8797;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function fail(reason) {
  console.log("BASARISIZ: " + reason);
  process.exit(1);
}

/* ---------- isletim sistemi pencereleri ---------- */

function openWindows() {
  const out = execFileSync(
    "powershell",
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", LIST_WINDOWS, "-ProcessName", IMAGE],
    { encoding: "utf8", windowsHide: true },
  );
  return out
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => {
      const [pid, title, visible] = line.split("\t");
      return { pid: Number(pid), title: title || "", visible: visible === "1" };
    });
}

async function until(label, timeoutMs, probe, intervalMs = 300) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await probe();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`${label}: ${timeoutMs} ms icinde gerceklesmedi`);
    await sleep(intervalMs);
  }
}

/* ---------- yerel kopru istemcisi ---------- */

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
        try {
          const parsed = JSON.parse(line);
          this.messages.push(parsed);
          for (const waiter of [...this.waiters]) waiter(parsed);
        } catch {
          /* JSON olmayan satir yoksayilir */
        }
      }
    });
    socket.on("close", () => (this.closed = true));
    socket.on("error", () => (this.closed = true));
  }

  send(object) {
    this.socket.write(`${JSON.stringify(object)}\n`);
  }

  waitFor(predicate, timeoutMs, label) {
    const found = this.messages.find(predicate);
    if (found) return Promise.resolve(found);

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== waiter);
        reject(
          new Error(`${label} zaman asimi. Son mesajlar: ${JSON.stringify(this.messages.slice(-4))}`),
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

let reqSeq = 0;

async function call(client, op, fields = {}, timeoutMs = 30000) {
  const reqId = `d${++reqSeq}`;
  client.send({ type: op, reqId, ...fields });
  const answer = await client.waitFor((m) => m.reqId === reqId, timeoutMs, `${op} yaniti`);
  if (answer.type === "error") {
    throw new Error(`${op}: ${answer.payload?.message || "bilinmeyen hata"}`);
  }
  return answer;
}

const taskList = (client) => call(client, "list").then((answer) => answer.payload);

async function waitTask(client, id, done, timeoutMs = 90000) {
  return until(
    `gorev ${id}`,
    timeoutMs,
    async () => {
      const task = (await taskList(client)).find((t) => t.id === id);
      return task && done(task) ? task : null;
    },
    300,
  );
}

async function connectBridge(dataDir) {
  const info = await until(
    "ipc.json",
    30000,
    () => {
      const path = join(dataDir, "ipc.json");
      if (!existsSync(path)) return null;
      try {
        const parsed = JSON.parse(readFileSync(path, "utf8"));
        return parsed.port && parsed.token ? parsed : null;
      } catch {
        return null;
      }
    },
    300,
  );

  const socket = netConnect({ host: "127.0.0.1", port: info.port });
  await new Promise((resolve, reject) => {
    socket.once("connect", resolve);
    socket.once("error", reject);
  });
  const client = new IpcClient(socket);

  client.send({ type: "hello", token: info.token });
  await client.waitFor((m) => m.type === "ready", 10000, "ready");
  return { client, info };
}

/* ---------- uygulama sureci ---------- */

function launch(dataDir) {
  const proc = spawn(EXE, [], {
    cwd: join(EXE, ".."),
    env: { ...process.env, SERENE_DATA_DIR: dataDir },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let log = "";
  proc.stdout.on("data", (chunk) => (log += chunk.toString()));
  proc.stderr.on("data", (chunk) => (log += chunk.toString()));
  proc.on("exit", (code) => (log += `\n[cikis ${code}]`));
  return { proc, log: () => log };
}

function killAll() {
  spawnSync("taskkill", ["/F", "/IM", `${IMAGE}.exe`, "/T"], {
    stdio: "ignore",
    windowsHide: true,
  });
}

async function startApp(dataDir) {
  rmSync(join(dataDir, "ipc.json"), { force: true });
  const app = launch(dataDir);
  const started = await connectBridge(dataDir);
  return { app, ...started };
}

/// Bir gorevi kuyruga verir ve `ack` bekler. Tur acikca `dash` gonderilir.
async function enqueue(client, url) {
  const ack = await call(client, "enqueue", { url, kind: "dash" }, 30000);
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
    `${label}: ${actual.length} bayt indi, beklenen ${expected.length} (gorev toplami=${task.total})`,
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

const report = {};
const problems = [];

async function main() {
  if (!existsSync(EXE)) fail("uygulama bulunamadi: " + EXE + " (once `flutter build windows --debug`)");
  if (openWindows().length) fail(`calisan bir ${IMAGE}.exe var; kosumdan once onu kapat`);

  const dataDir = mkdtempSync(join(tmpdir(), "serene-dash-"));
  const downloadDir = join(dataDir, "indir");
  mkdirSync(downloadDir);
  writeFileSync(
    join(dataDir, "settings.json"),
    JSON.stringify(
      {
        downloadDir,
        maxConcurrent: 2,
        connections: 2,
        watchClipboard: false,
        closeToTray: false,
        confirmBrowserDownload: false,
      },
      null,
      2,
    ),
  );

  const server = await startTestServer({ port: HTTP_PORT });
  console.log(`DASH test sunucusu: ${server.url("/dash/manifest.mpd")}`);
  console.log(`indirme klasoru: ${downloadDir}`);

  let client = null;
  let app = null;

  try {
    const started = await startApp(dataDir);
    app = started.app;
    client = started.client;
    console.log("kopru hazir");

    await call(client, "subscribe");
    await client.waitFor((m) => m.type === "subscribed", 10000, "subscribed");

    /* 1-2. SegmentTemplate + $Number$: video secilir, ayri ses inilmez */
    const task1 = await enqueue(client, server.url("/dash/manifest.mpd"));
    console.log(`gorev 1 kuyruga girdi: ${task1.filename}`);
    const done1 = await waitTask(
      client,
      task1.id,
      (t) => t.status === "completed" || t.status === "failed",
      60000,
    );
    if (done1.status !== "completed") {
      problems.push(`template: gorev tamamlanmadi (${done1.status}: ${done1.error})`);
    }
    report.templateStatus = done1.status;
    verifyFile(done1, EXPECTED.dash, "template", problems, report);
    if (!String(done1.dest).startsWith(downloadDir)) {
      problems.push("template: dosya indirme klasorunun disinda");
    }
    // Init parcasi basta olmali: dosya 0x21 deseniyle baslar, parcalar 0x50+.
    if (existsSync(done1.dest)) {
      const head = readFileSync(done1.dest);
      if (head[0] !== 0x21) problems.push("template: init parcasi basta degil");
      if (head.includes(0x90)) problems.push("template: ayri ses parcasi ciktiya karismis");
    }

    /* 3. SegmentTimeline + $Time$ + $RepresentationID$ */
    const task2 = await enqueue(client, server.url("/dash/timeline.mpd"));
    const done2 = await waitTask(
      client,
      task2.id,
      (t) => t.status === "completed" || t.status === "failed",
      60000,
    );
    if (done2.status !== "completed") {
      problems.push(`timeline: gorev tamamlanmadi (${done2.status}: ${done2.error})`);
    }
    report.timelineStatus = done2.status;
    verifyFile(done2, EXPECTED.dashTimeline, "timeline", problems, report);

    /* 4. Desteklenmeyen yapi: SegmentBase indexRange */
    const task3 = await enqueue(client, server.url("/dash/broken.mpd"));
    const done3 = await waitTask(
      client,
      task3.id,
      (t) => t.status === "completed" || t.status === "failed",
      60000,
    );
    report.broken = { status: done3.status, error: done3.error };
    console.log(`desteklenmeyen manifest: durum=${done3.status}, hata="${done3.error}"`);
    if (done3.status !== "failed") problems.push(`broken: gorev basarisiz olmadi (${done3.status})`);
    if (!String(done3.error || "").includes("indexRange")) {
      problems.push(`broken: hata mesaji aciklayici degil (${done3.error})`);
    }
    if (existsSync(done3.dest)) problems.push("broken: basarisiz gorev yine de dosya birakti");

    // Uygulama yasiyor mu: kopru ve komutlar hala yanit vermeli.
    const alive = (await taskList(client)).length;
    report.appAlive = alive >= 3;
    console.log(`desteklenmeyen manifest sonrasi uygulama ayakta: ${report.appAlive}`);
    if (!report.appAlive) problems.push("broken: uygulama hatadan sonra yanit vermiyor");

    client.close();
    client = null;
  } catch (error) {
    problems.push(error.stack || String(error));
    if (app) console.log(app.log().slice(-2000));
  } finally {
    killAll();
    await sleep(600);
    rmSync(dataDir, { recursive: true, force: true });
    await server.close();
  }

  console.log(JSON.stringify(report, null, 2));
  if (problems.length) fail(problems.join(" | "));
  console.log(
    "BASARILI: DASH SegmentTemplate $Number$, SegmentTimeline $Time$, video secimi, ayri sesin dislanmasi ve desteklenmeyen yapinin reddi dogrulandi",
  );
}

main();
