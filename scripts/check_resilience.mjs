// Serene dayaniklilik (resilience) dogrulamasi.
//
// Iki gercek senaryoyu gercek uygulamayla olcer:
//
//   A) Sunucu aralik (Range) DESTEKLEMIYORSA, yarim kalan indirmeye devam
//      edilince dosya BOZULMAMALI. Yarim parcanin uzerine bastan yazmak veri
//      bozar; motor bu durumda bastan inmeli. (engine.rs non-resumable duzeltmesi)
//
//   B) Bir HLS parcasi icin sunucu gecici 503 dondururse indirme parca basina
//      yeniden denemeli ve tamamlanmali. Yeniden deneme olmadan gorev duserdi.
//      (stream.rs retry/backoff)
//
// Kullanim:
//   cd flutter_app && flutter build windows --debug
//   node scripts/check_resilience.mjs
//
// Baska bir derleme icin: SERENE_APP_EXE=...\Serene.exe
// Her sey gecici bir klasorde yasar; %APPDATA%\Serene ve Indirilenler etkilenmez.

import { execFileSync, spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { connect as netConnect } from "node:net";

const ROOT = resolve(import.meta.dirname, "..");
const EXE =
  process.env.SERENE_APP_EXE ||
  join(ROOT, "flutter_app", "build", "windows", "x64", "runner", "Debug", "Serene.exe");
const IMAGE = "Serene";
const LIST_WINDOWS = join(ROOT, "scripts", "list_windows.ps1");
const HTTP_PORT = 8799;

// A) non-resumable govde: bilinen uzunluk, Range yok sayilir, yavas aksin ki
// duraklatma aninda parca yarim kalsin.
const PAYLOAD = Buffer.alloc(192 * 1024, 0x7a);
const DRIP_CHUNK = 16 * 1024;
const DRIP_DELAY_MS = 200;

// B) mini HLS: 3 parca; biri ilk isteklerde 503 doner.
const ts = (packets, byte) => Buffer.alloc(188 * packets, byte);
const HLS_SEGMENTS = [0, 1, 2].map((i) => ts(6, 0x30 + i));
const HLS_EXPECTED = Buffer.concat(HLS_SEGMENTS);
const FLAKY_INDEX = 1;
const FLAKY_FAILS = 2;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function fail(reason) {
  console.log("BASARISIZ: " + reason);
  process.exit(1);
}

/* ---------- yerel test sunucusu ---------- */

function startHttpServer() {
  let flakySeen = 0;
  const server = createServer((req, res) => {
    const path = new URL(req.url, `http://127.0.0.1:${HTTP_PORT}`).pathname;

    // A) Non-resumable: `Accept-Ranges` yok, `Range` yok sayilir, govde parca
    // parca ve yavas gonderilir.
    if (path === "/plain.bin") {
      res.writeHead(200, {
        "Content-Type": "application/octet-stream",
        "Content-Length": PAYLOAD.length,
        "Content-Disposition": 'attachment; filename="resume-testi.bin"',
      });
      let off = 0;
      const timer = setInterval(() => {
        if (off >= PAYLOAD.length) {
          clearInterval(timer);
          res.end();
          return;
        }
        res.write(PAYLOAD.subarray(off, off + DRIP_CHUNK));
        off += DRIP_CHUNK;
      }, DRIP_DELAY_MS);
      res.on("close", () => clearInterval(timer));
      return;
    }

    if (path === "/hls/index.m3u8") {
      const body = Buffer.from(
        `#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:0
${HLS_SEGMENTS.map((_, i) => `#EXTINF:4.0,\nseg${i}.ts`).join("\n")}
#EXT-X-ENDLIST
`,
        "utf8",
      );
      res.writeHead(200, {
        "Content-Type": "application/vnd.apple.mpegurl",
        "Content-Length": body.length,
        "Content-Disposition": 'attachment; filename="hls-flaky.ts"',
      });
      res.end(body);
      return;
    }

    const seg = /^\/hls\/seg(\d)\.ts$/.exec(path);
    if (seg) {
      const i = Number(seg[1]);
      // Gecici hata: ilk FLAKY_FAILS istekte 503. Tekrar deneme yoksa gorev duser.
      if (i === FLAKY_INDEX && flakySeen < FLAKY_FAILS) {
        flakySeen += 1;
        res.writeHead(503, { "Content-Type": "text/plain" });
        res.end("gecici");
        return;
      }
      const body = HLS_SEGMENTS[i];
      res.writeHead(200, { "Content-Type": "video/mp2t", "Content-Length": body.length });
      res.end(body);
      return;
    }

    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("yok");
  });

  return new Promise((resolve) =>
    server.listen(HTTP_PORT, "127.0.0.1", () =>
      resolve({ server, flakyHits: () => flakySeen }),
    ),
  );
}

/* ---------- isletim sistemi pencereleri ---------- */

function openWindows() {
  const out = execFileSync(
    "powershell",
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", LIST_WINDOWS, "-ProcessName", IMAGE],
    { encoding: "utf8", windowsHide: true },
  );
  return out.split(/\r?\n/).filter(Boolean);
}

async function until(label, timeoutMs, probe, intervalMs = 250) {
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
    socket.on("close", () => {});
    socket.on("error", () => {});
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
        reject(new Error(`${label} zaman asimi. Son mesajlar: ${JSON.stringify(this.messages.slice(-3))}`));
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
  const reqId = `r${++reqSeq}`;
  client.send({ type: op, reqId, ...fields });
  const answer = await client.waitFor((m) => m.reqId === reqId, timeoutMs, `${op} yaniti`);
  if (answer.type === "error") throw new Error(`${op}: ${answer.payload?.message || "hata"}`);
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
    250,
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
    250,
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
  spawnSync("taskkill", ["/F", "/IM", `${IMAGE}.exe`, "/T"], { stdio: "ignore", windowsHide: true });
}

async function startApp(dataDir) {
  rmSync(join(dataDir, "ipc.json"), { force: true });
  const app = launch(dataDir);
  const connected = await connectBridge(dataDir);
  return { app, ...connected };
}

/* ---------- ana akis ---------- */

const report = {};
const problems = [];

async function main() {
  if (!existsSync(EXE)) fail("uygulama bulunamadi: " + EXE + " (once `flutter build windows --debug`)");
  if (openWindows().length) fail(`calisan bir ${IMAGE}.exe var; kosumdan once onu kapat`);

  // Gecici klasor agac icinde tutulur: LOW butunlukte %TEMP% yazilamaz
  // (MASTER §11), motor oraya kayit birakamaz.
  const dataDir = join(ROOT, "build", "verify-resil");
  rmSync(dataDir, { recursive: true, force: true });
  const downloadDir = join(dataDir, "indir");
  mkdirSync(downloadDir, { recursive: true });
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

  const http = await startHttpServer();
  let client = null;
  let app = null;

  try {
    const started = await startApp(dataDir);
    app = started.app;
    client = started.client;
    await call(client, "subscribe");
    await client.waitFor((m) => m.type === "subscribed", 10000, "subscribed");

    /* A) Non-resumable + duraklat/devam: dosya bozulmamali. */
    const ackA = await call(client, "enqueue", {
      url: `http://127.0.0.1:${HTTP_PORT}/plain.bin`,
    });
    const idA = ackA.payload.id;
    report.nonResumable = { id: idA, filename: ackA.payload.filename, total: ackA.payload.total };

    await client.waitFor(
      (m) => m.type === "progress" && (m.payload || []).some((t) => t.id === idA),
      30000,
      "A ilerleme",
    );
    // Parcalar biriksin ki duraklatma aninda yarim bir parca kalsin; aksi
    // halde "bastan indir" ile "devam et" ayrimi hic olculemez.
    await sleep(1200);
    await call(client, "pause", { id: idA });
    const pausedA = await waitTask(client, idA, (t) => t.status === "paused", 30000);
    // Yarim kalan parca olsun: duraklatma sirasinda birkaç chunk inmis olmali.
    report.nonResumable.pausedDownloaded = pausedA.downloaded;
    if (!(pausedA.downloaded > 0 && pausedA.downloaded < PAYLOAD.length)) {
      problems.push(`A: duraklatmada beklenen yarim boyut yok: ${pausedA.downloaded}`);
    }
    await call(client, "resume", { id: idA });
    const doneA = await waitTask(client, idA, (t) => t.status === "completed", 60000);
    const fileA = join(downloadDir, "resume-testi.bin");
    const bytesA = existsSync(fileA) ? readFileSync(fileA) : Buffer.alloc(0);
    report.nonResumable.completed = { downloaded: doneA.downloaded, actualBytes: bytesA.length };
    if (!bytesA.equals(PAYLOAD)) {
      problems.push(
        `A: bozuk dosya: ${bytesA.length} bayt (beklenen ${PAYLOAD.length}); icerik esit degil`,
      );
    }

    /* B) HLS parcasina gecici 503: yeniden deneme ile tamamlanmali. */
    const ackB = await call(client, "enqueue", {
      url: `http://127.0.0.1:${HTTP_PORT}/hls/index.m3u8`,
      kind: "hls",
    });
    const idB = ackB.payload.id;
    report.flakyHls = { id: idB, filename: ackB.payload.filename };
    const doneB = await waitTask(client, idB, (t) => t.status === "completed", 60000);
    const fileB = join(downloadDir, "hls-flaky.ts");
    const bytesB = existsSync(fileB) ? readFileSync(fileB) : Buffer.alloc(0);
    report.flakyHls.completed = { downloaded: doneB.downloaded, actualBytes: bytesB.length };
    report.flakyHls.transient503 = http.flakyHits();
    if (!bytesB.equals(HLS_EXPECTED)) {
      problems.push(
        `B: bozuk dosya: ${bytesB.length} bayt (beklenen ${HLS_EXPECTED.length}); icerik esit degil`,
      );
    }
    if (http.flakyHits() < FLAKY_FAILS) {
      problems.push(`B: beklenen 503 sayisi gelmedi: ${http.flakyHits()}`);
    }
  } catch (error) {
    problems.push(error.stack || String(error));
    if (app) console.log(app.log().slice(-2000));
  } finally {
    if (client) client.close();
    killAll();
    await sleep(600);
    http.server.close();
    rmSync(dataDir, { recursive: true, force: true });
  }

  console.log(JSON.stringify(report, null, 2));
  if (problems.length) fail(problems.join(" | "));
  console.log(
    "BASARILI: non-resumable devam dosyayi bozmuyor ve akis parcalari gecici hatada yeniden deneniyor",
  );
}

main();
