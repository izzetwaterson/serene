// Serene HLS akis indiricisi dogrulamasi (Faz 5).
//
// Gercek uygulama baslatilir, yerel kopruye baglanilir ve HLS gorevleri
// `enqueue` ile verilir; sonuc dosyalari diskten okunup bayt bayt karsilastirilir.
// Webview surulmez: tum adimlar kopru protokolu uzerinden yurutulur.
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
// Kullanim:
//   cd flutter_app && flutter build windows --debug
//   node scripts/check_hls.mjs
//
// Baska bir derlemeyi denemek icin: SERENE_APP_EXE=...\serene_app.exe
// Her sey gecici bir klasorde yasar: kullanicinin %APPDATA%\Serene'i ve
// Indirilenler'i etkilenmez.

import { spawn, spawnSync, execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { connect as netConnect } from "node:net";

import {
  EXPECTED,
  REQUIRED_COOKIE,
  REQUIRED_REFERER,
  start as startHlsServer,
} from "./serve_hls_test.mjs";

const ROOT = resolve(import.meta.dirname, "..");
const EXE =
  process.env.SERENE_APP_EXE ||
  join(ROOT, "flutter_app", "build", "windows", "x64", "runner", "Debug", "serene_app.exe");
const IMAGE = "serene_app";
const LIST_WINDOWS = join(ROOT, "scripts", "list_windows.ps1");
const HTTP_PORT = 8796;

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
  const reqId = `h${++reqSeq}`;
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

/// Bir gorevi kuyruga verir ve `ack` bekler. Tur acikca `hls` gonderilir.
async function enqueue(client, url, extra = {}) {
  const ack = await call(client, "enqueue", { url, kind: "hls", ...extra }, 30000);
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
}

/* ---------- ana akis ---------- */

const report = {};
const problems = [];

async function main() {
  if (!existsSync(EXE)) fail("uygulama bulunamadi: " + EXE + " (once `flutter build windows --debug`)");
  if (openWindows().length) fail(`calisan bir ${IMAGE}.exe var; kosumdan once onu kapat`);

  const dataDir = mkdtempSync(join(tmpdir(), "serene-hls-"));
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

  const hls = await startHlsServer({ port: HTTP_PORT });
  console.log(`HLS test sunucusu: ${hls.url("/master.m3u8")}`);
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

    /* 1. Master playlist -> en yuksek bant genisligi + init parcasi */
    const task1 = await enqueue(client, hls.url("/master.m3u8"));
    console.log(`gorev 1 kuyruga girdi: ${task1.filename}`);
    const done1 = await waitTask(
      client,
      task1.id,
      (t) => t.status === "completed" || t.status === "failed",
      60000,
    );
    if (done1.status !== "completed") {
      problems.push(`master: gorev tamamlanmadi (${done1.status}: ${done1.error})`);
    }
    report.masterStatus = done1.status;
    verifyFile(done1, EXPECTED.master, "master", problems, report);
    if (!String(done1.dest).startsWith(downloadDir)) {
      problems.push("master: dosya indirme klasorunun disinda");
    }
    // Init parcasi basta olmali: dosya 0x11 deseniyle baslar, parcalar 0x40+.
    if (existsSync(done1.dest)) {
      if (readFileSync(done1.dest)[0] !== 0x11) {
        problems.push("master: #EXT-X-MAP init parcasi basta degil");
      }
    }

    /* 2. AES-128 sifreli akis */
    const task2 = await enqueue(client, hls.url("/aes/index.m3u8"));
    const done2 = await waitTask(
      client,
      task2.id,
      (t) => t.status === "completed" || t.status === "failed",
      60000,
    );
    if (done2.status !== "completed") {
      problems.push(`aes: gorev tamamlanmadi (${done2.status}: ${done2.error})`);
    }
    report.aesStatus = done2.status;
    verifyFile(done2, EXPECTED.aes, "aes", problems, report);

    /* 3. Referer + Cookie isteyen varyant */
    const task3 = await enqueue(client, hls.url("/auth/master.m3u8"), {
      referer: REQUIRED_REFERER,
      cookie: `a=1; ${REQUIRED_COOKIE}`,
    });
    const done3 = await waitTask(
      client,
      task3.id,
      (t) => t.status === "completed" || t.status === "failed",
      60000,
    );
    if (done3.status !== "completed") {
      problems.push(`auth: gorev tamamlanmadi (${done3.status}: ${done3.error})`);
    }
    report.authStatus = done3.status;
    verifyFile(done3, EXPECTED.auth, "auth", problems, report);

    /* 4. Duraklat / devam */
    const task4 = await enqueue(client, hls.url("/slow/index.m3u8"));
    await sleep(900); // ilk parcalar bitsin, sonrakiler yarim kalsin
    await call(client, "pause", { id: task4.id });
    const paused = await waitTask(client, task4.id, (t) => t.status === "paused", 20000);
    report.pause = { status: paused.status, downloaded: paused.downloaded };
    console.log(`duraklatildi: durum=${paused.status}, inen=${paused.downloaded}`);
    if (!(paused.downloaded > 0 && paused.downloaded < EXPECTED.slow.length)) {
      problems.push(`duraklat: ilerleme beklenen aralikta degil (${paused.downloaded})`);
    }

    await call(client, "resume", { id: task4.id });
    const done4 = await waitTask(
      client,
      task4.id,
      (t) => t.status === "completed" || t.status === "failed",
      60000,
    );
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
      `duraklat/devam sirasinda ilerleme paketi: ${ticks.length} (en yuksek inen=${report.maxTickBytes})`,
    );
    if (ticks.length === 0) problems.push("duraklat/devam: hic ilerleme paketi gelmedi");
    if (report.maxTickBytes === 0) problems.push("duraklat/devam: ilerleme paketleri bos");

    /* 5. DRM reddi */
    const task5 = await enqueue(client, hls.url("/drm/index.m3u8"));
    const done5 = await waitTask(
      client,
      task5.id,
      (t) => t.status === "completed" || t.status === "failed",
      60000,
    );
    report.drm = { status: done5.status, error: done5.error };
    console.log(`DRM gorevi: durum=${done5.status}, hata="${done5.error}"`);
    if (done5.status !== "failed") problems.push(`drm: gorev basarisiz olmadi (${done5.status})`);
    if (!String(done5.error || "").includes("DRM")) {
      problems.push(`drm: hata mesaji aciklayici degil (${done5.error})`);
    }
    if (existsSync(done5.dest)) problems.push("drm: basarisiz gorev yine de dosya birakti");

    // Uygulama yasiyor mu: kopru ve komutlar hala yanit vermeli.
    const alive = (await taskList(client)).length;
    report.appAlive = alive >= 5;
    console.log(`DRM sonrasi uygulama ayakta: ${report.appAlive} (gorev sayisi=${alive})`);
    if (!report.appAlive) problems.push("drm: uygulama DRM hatasindan sonra yanit vermiyor");

    client.close();
    client = null;
  } catch (error) {
    problems.push(error.stack || String(error));
    if (app) console.log(app.log().slice(-2000));
  } finally {
    killAll();
    await sleep(600);
    rmSync(dataDir, { recursive: true, force: true });
    await hls.close();
  }

  console.log(JSON.stringify(report, null, 2));
  if (problems.length) fail(problems.join(" | "));
  console.log(
    "BASARILI: HLS varyant secimi, birlestirme, AES-128, basliklar, duraklat/devam ve DRM reddi dogrulandi",
  );
}

main();
