// Serene yerel kopru (bridge) dogrulamasi.
//
// Gercek uygulama baslatilir ve yerel kopru dogrudan konusturulur: webview
// surulmez, yalnizca tel bicimi denetlenir. Boylece protokol kabuktan bagimsiz
// olarak sınanir.
//
// Dogrulananlar:
//   1. ipc.json yazilir; port, pid, surum ve rastgele token (>=32) icerir
//   2. Token'siz ve yanlis token'li baglanti reddedilir, soket kapanir
//   3. Dogru token ile el sikismasi "ready" doner
//   4. Bilinmeyen komut hata doner; yanitlar token'i sizdirmaz
//   5. ping -> pong (pid uygulamayla ayni, clients canli baglanti sayisi)
//   6. subscribe -> subscribed; enqueue -> ack + progress olaylari; dosya
//      hedef klasore bayt bayt iner
//   7. pause/resume durum gecisleri kopruden surulur
//   8. remove gorevi listeden dusurur
//   9. Uygulama kapaninca ipc.json silinir
//
// Kullanim:
//   cd flutter_app && flutter build windows --debug
//   node scripts/check_bridge.mjs
//
// Baska bir derlemeyi denemek icin: SERENE_APP_EXE=...\Serene.exe
// Her sey gecici bir klasorde yasar: kullanicinin %APPDATA%\Serene'i ve
// Indirilenler'i etkilenmez.

import { execFileSync, spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { connect as netConnect } from "node:net";

const ROOT = resolve(import.meta.dirname, "..");
const EXE =
  process.env.SERENE_APP_EXE ||
  join(ROOT, "flutter_app", "build", "windows", "x64", "runner", "Debug", "Serene.exe");
const IMAGE = "Serene";
const LIST_WINDOWS = join(ROOT, "scripts", "list_windows.ps1");
const HTTP_PORT = 8793;

const DRIP_CHUNK = 16 * 1024;
const DRIP_DELAY_MS = 300;
const PAYLOAD = Buffer.alloc(192 * 1024, 0x51);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function fail(reason) {
  console.log("BASARISIZ: " + reason);
  process.exit(1);
}

/* ---------- yerel test sunucusu ---------- */

/// Govdeyi parca parca gonderir: indirme, ilerleme tikinden (400 ms) uzun
/// surmeli ki `progress` olaylari aksin.
function startHttpServer() {
  const server = createServer((req, res) => {
    const total = PAYLOAD.length;
    const range = /bytes=(\d+)-(\d*)/.exec(req.headers.range || "");
    const start = range ? Number(range[1]) : 0;
    const end = range ? (range[2] ? Number(range[2]) : total - 1) : total - 1;

    const headers = {
      "Content-Type": "application/octet-stream",
      "Content-Length": end - start + 1,
      "Accept-Ranges": "bytes",
      "Content-Disposition": 'attachment; filename="kopru-kuyruk.bin"',
    };
    if (range) headers["Content-Range"] = `bytes ${start}-${end}/${total}`;
    res.writeHead(range ? 206 : 200, headers);

    const slice = PAYLOAD.subarray(start, end + 1);
    let offset = 0;
    const timer = setInterval(() => {
      if (offset >= slice.length) {
        clearInterval(timer);
        res.end();
        return;
      }
      res.write(slice.subarray(offset, offset + DRIP_CHUNK));
      offset += DRIP_CHUNK;
    }, DRIP_DELAY_MS);
    res.on("close", () => clearInterval(timer));
  });

  return new Promise((resolve) => server.listen(HTTP_PORT, "127.0.0.1", () => resolve(server)));
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
    this.closers = [];
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
    socket.on("close", () => this._closed());
    socket.on("error", () => this._closed());
  }

  _closed() {
    this.closed = true;
    for (const closer of this.closers) closer();
    this.closers = [];
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

  /// Sunucunun baglantiyi kapatmasi beklenir (reddedilen el sikismasi).
  waitForClose(timeoutMs, label) {
    if (this.closed) return Promise.resolve(true);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.closers = this.closers.filter((c) => c !== closer);
        reject(new Error(`${label} zaman asimi`));
      }, timeoutMs);
      const closer = () => {
        clearTimeout(timer);
        this.closers = this.closers.filter((c) => c !== closer);
        resolve(true);
      };
      this.closers.push(closer);
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
  const reqId = `k${++reqSeq}`;
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

/// El sikismasi olmadan baglanir: token denemeleri icin.
async function rawConnect(dataDir) {
  const info = JSON.parse(readFileSync(join(dataDir, "ipc.json"), "utf8"));
  const socket = netConnect({ host: "127.0.0.1", port: info.port });
  await new Promise((resolve, reject) => {
    socket.once("connect", resolve);
    socket.once("error", reject);
  });
  return { client: new IpcClient(socket), info };
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

/// `/F` olmadan Windows pencereye WM_CLOSE gonderir: uygulama kapanirken
/// kopru kaydini (`ipc.json`) kendisi siler.
function closeGracefully() {
  spawnSync("taskkill", ["/IM", `${IMAGE}.exe`, "/T"], {
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

/* ---------- ana akis ---------- */

const report = {};
const problems = [];

async function main() {
  if (!existsSync(EXE)) fail("uygulama bulunamadi: " + EXE + " (once `flutter build windows --debug`)");
  if (openWindows().length) fail(`calisan bir ${IMAGE}.exe var; kosumdan once onu kapat`);

  const dataDir = mkdtempSync(join(tmpdir(), "serene-bridge-"));
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

  const httpServer = await startHttpServer();
  let client = null;
  let app = null;

  try {
    /* 1: ipc.json alanlari */
    const first = await startApp(dataDir);
    app = first.app;
    client = first.client;
    const info = first.info;
    report.ipc = { port: info.port, pid: info.pid, version: info.version };
    if (!Number.isInteger(info.port) || info.port <= 0) problems.push("ipc.json port gecersiz");
    if (!info.token || info.token.length < 32) problems.push("ipc.json token'i kisa");
    if (info.pid !== app.proc.pid) {
      problems.push(`ipc.json pid uygulamayla ayni degil: ${info.pid} != ${app.proc.pid}`);
    }

    /* 2: tokensiz ve yanlis token'li baglanti reddedilir */
    const bare = await rawConnect(dataDir);
    bare.client.send({ type: "ping" });
    const rejected = await bare.client.waitFor((m) => m.type === "error", 10000, "tokensiz reddi");
    report.tokenlessRejection = rejected.payload?.message;
    await bare.client.waitForClose(10000, "tokensiz kapanis");
    bare.client.close();

    const wrong = await rawConnect(dataDir);
    wrong.client.send({ type: "hello", token: "yanlis-token" });
    const wrongRejected = await wrong.client.waitFor(
      (m) => m.type === "error",
      10000,
      "yanlis token reddi",
    );
    report.wrongTokenRejection = wrongRejected.payload?.message;
    await wrong.client.waitForClose(10000, "yanlis token kapanisi");
    wrong.client.close();

    /* 3-4: ping/pong + bilinmeyen komut + token sizmaz */
    const pong = await call(client, "ping");
    report.ping = pong.payload;
    if (pong.payload?.pid !== app.proc.pid) {
      problems.push(`ping pid'i uygulamayla ayni degil: ${pong.payload?.pid}`);
    }
    if (pong.payload?.clients !== 1) {
      problems.push(`ping clients=1 bekleniyordu: ${pong.payload?.clients}`);
    }
    if (JSON.stringify(pong).includes(info.token)) problems.push("ping yaniti token'i sizdirdi");

    let unknown = null;
    try {
      await call(client, "olmayan_komut");
      problems.push("bilinmeyen komut hata dondurmedi");
    } catch (error) {
      unknown = String(error.message);
    }
    report.unknownCommand = unknown;
    if (unknown && !unknown.includes("bilinmeyen komut")) {
      problems.push(`bilinmeyen komut mesaji beklenen degil: ${unknown}`);
    }

    /* 5: ikinci baglanti clients sayisini artirir, kapaninca duser */
    const peer = await rawConnect(dataDir);
    peer.client.send({ type: "hello", token: info.token });
    await peer.client.waitFor((m) => m.type === "ready", 10000, "peer ready");
    const both = await call(client, "ping");
    report.clientsWithPeer = both.payload?.clients;
    if (both.payload?.clients !== 2) {
      problems.push(`ikinci baglanti clients=2 uretmedi: ${both.payload?.clients}`);
    }
    peer.client.close();
    const alone = await until(
      "clients sayisinin dusmesi",
      15000,
      async () => {
        const answer = await call(client, "ping");
        return answer.payload?.clients === 1 ? answer.payload : null;
      },
      400,
    );
    report.clientsAfterPeer = alone.clients;

    /* 6: subscribe + enqueue + olay akisi + disk */
    await call(client, "subscribe");
    await client.waitFor((m) => m.type === "subscribed", 10000, "subscribed");

    const ack = await call(client, "enqueue", { url: `http://127.0.0.1:${HTTP_PORT}/kuyruk.bin` });
    const taskId = ack.payload.id;
    report.enqueue = { id: taskId, filename: ack.payload.filename, total: ack.payload.total };
    if (ack.payload.total !== PAYLOAD.length) {
      problems.push(`ack boyutu beklenen degil: ${ack.payload.total}`);
    }

    await client.waitFor(
      (m) => m.type === "progress" && (m.payload || []).some((tick) => tick.id === taskId),
      30000,
      "ilerleme olayi",
    );

    /* 7: pause -> paused, resume -> completed */
    await call(client, "pause", { id: taskId });
    const paused = await waitTask(client, taskId, (t) => t.status === "paused", 30000);
    report.paused = paused.status;
    await call(client, "resume", { id: taskId });

    const finished = await waitTask(client, taskId, (t) => t.status === "completed");
    report.completed = { downloaded: finished.downloaded, dest: finished.dest };
    const landed = join(downloadDir, "kopru-kuyruk.bin");
    if (!existsSync(landed) || !readFileSync(landed).equals(PAYLOAD)) {
      problems.push("kopru-kuyruk.bin hedef klasorde beklenen icerikle bulunamadi");
    }

    /* 8: remove gorevi listeden dusurur */
    await call(client, "remove", { id: taskId });
    const gone = await until(
      "gorevin listeden dusmesi",
      15000,
      async () => ((await taskList(client)).some((t) => t.id === taskId) ? null : true),
      300,
    );
    report.removed = gone;

    /* 9: kapanista ipc.json silinir */
    client.close();
    client = null;
    closeGracefully();
    const removed = await until(
      "ipc.json silinmesi",
      25000,
      () => (openWindows().length === 0 && !existsSync(join(dataDir, "ipc.json")) ? true : null),
      400,
    );
    report.ipcRemoved = removed;
  } catch (error) {
    problems.push(error.stack || String(error));
    if (app) console.log(app.log().slice(-2000));
  } finally {
    killAll();
    await sleep(600);
    httpServer.close();
    rmSync(dataDir, { recursive: true, force: true });
  }

  console.log(JSON.stringify(report, null, 2));
  if (problems.length) fail(problems.join(" | "));
  console.log(
    "BASARILI: kopru protokolu, olay akisi, duraklat/devam ve kapanis temizligi dogrulandi",
  );
}

main();
