// Serene yerel kopru (bridge) dogrulamasi.
//
// Dogrulananlar:
//   1. ipc.json yazilir; port ve rastgele token icerir
//   2. Token olmadan / yanlis token ile baglanti reddedilir
//   3. Dogru token ile el sikisma "ready" doner
//   4. ping -> pong (pid uygulamayla ayni)
//   5. subscribe -> subscribed, ardindan enqueue -> ack + tasks/progress olaylari
//   6. bridge_status komutu canli baglanti sayisini bildirir
//   7. Uygulama kapaninca ipc.json silinir
//
// Kullanim: node scripts/check_bridge.mjs

import { execSync, spawn } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { connect as netConnect } from "node:net";

// Baska bir derlemeyi denemek icin: SERENE_EXE=...\target\release\serene.exe
const EXE =
  process.env.SERENE_EXE ||
  "C:\\Users\\izzet\\Desktop\\serene\\src-tauri\\target\\debug\\serene.exe";
const CWD = "C:\\Users\\izzet\\Desktop\\serene\\src-tauri";
const IPC_PATH = join(process.env.APPDATA, "Serene", "ipc.json");
const PORT = Number(process.env.SERENE_CDP_PORT || 9335);
const HTTP_PORT = 8793;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/* ---------- yerel test sunucusu ---------- */

const PAYLOAD = Buffer.alloc(192 * 1024, 0x51);
const DRIP_CHUNK = 16 * 1024;
const DRIP_DELAY_MS = 300;

/// Govdeyi parca parca gonderir. Amac: indirmeyi 400 ms'lik ilerleme
/// tikinden daha uzun surdurmek, boylece `tasks:progress` olaylari aksin.
function drip(res, buffer, onDone) {
  let offset = 0;
  const timer = setInterval(() => {
    if (offset >= buffer.length) {
      clearInterval(timer);
      res.end();
      onDone?.();
      return;
    }
    const slice = buffer.subarray(offset, offset + DRIP_CHUNK);
    offset += slice.length;
    res.write(slice);
  }, DRIP_DELAY_MS);

  res.on("close", () => clearInterval(timer));
}

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
        "Content-Disposition": 'attachment; filename="kopru-testi.bin"',
      });
      drip(res, PAYLOAD.subarray(start, end + 1));
      return;
    }

    res.writeHead(200, {
      "Content-Type": "application/octet-stream",
      "Content-Length": total,
      "Accept-Ranges": "bytes",
      "Content-Disposition": 'attachment; filename="kopru-testi.bin"',
    });
    drip(res, PAYLOAD);
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

  /** Verilen kosula uyan ilk mesaji bekler (once birikmisler taranir). */
  waitFor(predicate, timeoutMs = 15000, label = "mesaj") {
    const found = this.messages.find(predicate);
    if (found) return Promise.resolve(found);

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== waiter);
        reject(
          new Error(
            `${label} zaman asimi. Gelenler: ${JSON.stringify(this.messages.slice(-6))}`
          )
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

  async waitForClose(timeoutMs = 8000) {
    if (this.closed) return true;
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (this.closed) return true;
      await sleep(100);
    }
    return false;
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

  const httpServer = await startHttpServer();

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

    /* 1. ipc.json */
    const deadline = Date.now() + 15000;
    while (!existsSync(IPC_PATH) && Date.now() < deadline) await sleep(300);
    if (!existsSync(IPC_PATH)) throw new Error("ipc.json olusmadi");

    const info = JSON.parse(readFileSync(IPC_PATH, "utf8"));
    report.ipcFile = {
      port: info.port,
      tokenLength: String(info.token || "").length,
      pid: info.pid,
      version: info.version,
    };
    console.log(
      `ipc.json: port=${info.port}, token uzunlugu=${report.ipcFile.tokenLength}, pid=${info.pid}, surum=${info.version}`
    );
    if (!info.port) problems.push("ipc.json port alani bos");
    if (!info.token || String(info.token).length < 32) {
      problems.push("ipc.json token yeterince uzun degil");
    }

    /* 2a. Yanlis token */
    const bad = await openIpc(info.port);
    bad.send({ type: "hello", token: "yanlis-token" });
    const badError = await bad.waitFor((m) => m.type === "error", 8000, "yanlis token hatasi");
    report.badToken = { error: badError.payload?.message, closed: await bad.waitForClose() };
    console.log(`yanlis token: "${report.badToken.error}", baglanti kapandi: ${report.badToken.closed}`);
    bad.close();
    if (report.badToken.closed !== true) problems.push("yanlis token sonrasi baglanti kapanmadi");

    /* 2b. El sikismasi olmadan komut */
    const noHello = await openIpc(info.port);
    noHello.send({ type: "ping" });
    const noHelloError = await noHello.waitFor(
      (m) => m.type === "error",
      8000,
      "el sikismasi hatasi"
    );
    report.noHello = {
      error: noHelloError.payload?.message,
      closed: await noHello.waitForClose(),
    };
    console.log(
      `el sikismasiz istek: "${report.noHello.error}", baglanti kapandi: ${report.noHello.closed}`
    );
    noHello.close();
    if (report.noHello.closed !== true) problems.push("el sikismasiz istekte baglanti kapanmadi");

    /* 3-5. Dogru token ile tam akis */
    const client = await openIpc(info.port);
    client.send({ type: "hello", token: info.token });
    const ready = await client.waitFor((m) => m.type === "ready", 10000, "ready");
    report.ready = ready.payload;
    console.log(`el sikisma tamam: surum=${ready.payload.version}, port=${ready.payload.port}`);

    client.send({ type: "ping" });
    const pong = await client.waitFor((m) => m.type === "pong", 8000, "pong");
    report.pong = pong.payload;
    console.log(`pong: pid=${pong.payload.pid}, istemci=${pong.payload.clients}`);
    if (pong.payload.pid !== info.pid) problems.push("pong pid'i uygulama pid'i ile ayni degil");
    if (pong.payload.clients !== 1) {
      problems.push(`pong istemci sayisi 1 degil (${pong.payload.clients})`);
    }

    /* Kopru durumu arayuzden okunabiliyor mu? */
    report.bridgeStatus = await cdp.evaluate(
      `(async () => await window.__TAURI__.core.invoke("bridge_status"))()`,
      true
    );
    console.log(
      `bridge_status: port=${report.bridgeStatus.port}, istemci=${report.bridgeStatus.clients}`
    );
    if (report.bridgeStatus.clients !== 1) {
      problems.push(`bridge_status istemci sayisi 1 degil (${report.bridgeStatus.clients})`);
    }
    if (report.bridgeStatus.token !== undefined) {
      problems.push("bridge_status token sizdirdi");
    }

    client.send({ type: "subscribe" });
    await client.waitFor((m) => m.type === "subscribed", 8000, "subscribed");
    console.log("abonelik kuruldu");

    const url = `http://127.0.0.1:${HTTP_PORT}/kopru-testi.bin`;
    client.send({ type: "enqueue", reqId: "r1", url });

    const ack = await client.waitFor(
      (m) => m.type === "ack" && m.reqId === "r1",
      30000,
      "ack"
    );
    report.ack = {
      id: ack.payload.id,
      filename: ack.payload.filename,
      status: ack.payload.status,
      total: ack.payload.total,
      segments: Array.isArray(ack.payload.segments) ? ack.payload.segments.length : null,
    };
    console.log(
      `ack: ${report.ack.filename}, durum=${report.ack.status}, boyut=${report.ack.total}, parca=${report.ack.segments}`
    );
    if (report.ack.total !== PAYLOAD.length) {
      problems.push(`ack boyutu beklenen ${PAYLOAD.length} degil (${report.ack.total})`);
    }

    /* Olay akisi: abone oldugumuz icin ilerleme paketleri gelmeli. */
    const progress = await client.waitFor((m) => m.type === "progress", 30000, "progress");
    const firstTick = progress.payload.find((tick) => tick.id === report.ack.id);
    report.progressEvent = {
      firstDownloaded: firstTick?.downloaded ?? null,
      midFlight: Boolean(firstTick && firstTick.downloaded < PAYLOAD.length),
    };
    console.log(
      `ilk progress olayi: inen=${report.progressEvent.firstDownloaded}/${PAYLOAD.length} (devam ederken)`
    );
    if (!firstTick) problems.push("progress olayinda bizim gorev yok");
    if (!report.progressEvent.midFlight) {
      problems.push("ilk progress olayi indirme bitmeden gelmedi");
    }

    /* Indirme tamamlanana kadar bekle. */
    const finishDeadline = Date.now() + 60000;
    let finalTask = null;
    while (Date.now() < finishDeadline) {
      const tasks = await cdp.evaluate(
        `(async () => await window.__TAURI__.core.invoke("list_tasks"))()`,
        true
      );
      finalTask = tasks.find((task) => task.id === report.ack.id);
      if (finalTask && (finalTask.status === "completed" || finalTask.status === "failed")) break;
      await sleep(500);
    }
    report.finalStatus = finalTask?.status;
    report.finalDownloaded = finalTask?.downloaded;
    console.log(`indirme sonucu: durum=${report.finalStatus}, inen=${report.finalDownloaded}`);
    if (report.finalStatus !== "completed") {
      problems.push(`indirme tamamlanmadi (${report.finalStatus})`);
    }
    if (report.finalDownloaded !== PAYLOAD.length) {
      problems.push(`inen bayt beklenen degil (${report.finalDownloaded})`);
    }

    /* tasks olayi da akmis olmali. */
    const tasksEvent = client.messages.find((m) => m.type === "tasks");
    report.tasksEventSeen = Boolean(tasksEvent);
    if (!tasksEvent) problems.push("tasks olayi hic gelmedi");

    /* Abonelikten cikinca istemci sayisi duser. */
    client.close();
    await sleep(1200);
    report.statusAfterClose = await cdp.evaluate(
      `(async () => await window.__TAURI__.core.invoke("bridge_status"))()`,
      true
    );
    console.log(`baglanti kapaninca istemci sayisi: ${report.statusAfterClose.clients}`);
    if (report.statusAfterClose.clients !== 0) {
      problems.push(`baglanti kapaninca istemci sayisi 0 degil (${report.statusAfterClose.clients})`);
    }

    /* 7. Kapanista ipc.json silinir */
    await cdp.evaluate(
      `(async () => {
        const s = await window.__TAURI__.core.invoke("get_settings");
        s.closeToTray = false;
        await window.__TAURI__.core.invoke("update_settings", { settings: s });
        return true;
      })()`,
      true
    );
    try {
      await Promise.race([
        cdp.evaluate(
          `(async () => { await window.__TAURI__.window.getCurrentWindow().close(); return true; })()`,
          true
        ),
        sleep(1500),
      ]);
    } catch {
      /* soket kapandi */
    }

    const exitDeadline = Date.now() + 15000;
    while (existsSync(IPC_PATH) && Date.now() < exitDeadline) await sleep(300);
    report.ipcFileRemovedOnExit = !existsSync(IPC_PATH);
    console.log(`kapanista ipc.json silindi: ${report.ipcFileRemovedOnExit}`);
    if (!report.ipcFileRemovedOnExit) problems.push("kapanista ipc.json silinmedi");

    /* Test kaydini temizle */
    try {
      execSync('taskkill /F /IM serene.exe /T', { stdio: "ignore", windowsHide: true });
    } catch {
      /* kapali */
    }
    await sleep(800);

    console.log("");
    console.log(JSON.stringify(report, null, 2));
    console.log("");
    if (problems.length) {
      failed = true;
      console.log(`BASARISIZ: ${problems.join("; ")}`);
    } else {
      console.log("BASARILI: yerel kopru token, komutlar ve olay akisi dogrulandi");
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
    httpServer.close();
  }

  process.exit(failed ? 1 : 0);
}

main().catch((error) => {
  console.log(`beklenmeyen hata: ${error.message}`);
  process.exit(2);
});
