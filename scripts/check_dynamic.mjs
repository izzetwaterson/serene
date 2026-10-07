// Serene dinamik segmentasyon dogrulamasi.
//
// Gercek uygulamayla olcer: yerel, Range DESTEKLEYEN bir sunucudan 32 MiB
// indirir ve yalnizca bir parcanin baslangicini cok yavas besler. Motor o
// parcayi bolup kalan araligi yeni bir baglantiya vermeli: gorev listesinde
// parca sayisi artmali, sunucu yeni bir Range istemeli ve indirme yine de
// tamamlanip dosya bayt-bayt kaynakla esit olmali.
//
// Kullanim:
//   cd flutter_app && flutter build windows --release
//   node scripts/check_dynamic.mjs
// Baska bir derleme icin: SERENE_APP_EXE=...\Serene.exe

import { spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { connect as netConnect } from "node:net";

const ROOT = resolve(import.meta.dirname, "..");
const EXE =
  process.env.SERENE_APP_EXE ||
  join(ROOT, "flutter_app", "build", "windows", "x64", "runner", "Debug", "Serene.exe");
const IMAGE = "Serene";
const HTTP_PORT = 8801;
const SIZE = 32 * 1024 * 1024;
const CONNECTIONS = 8;
const SEGMENT = SIZE / CONNECTIONS; // 4 MiB
const SLOW_START = 3 * SEGMENT; // 3. parcanin baslangici
const FAST_CHUNK = 128 * 1024;
const FAST_DELAY = 50;
const SLOW_CHUNK = 16 * 1024;
const SLOW_DELAY = 250;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function fail(reason) {
  console.log("BASARISIZ: " + reason);
  process.exit(1);
}

function startServer() {
  const body = Buffer.alloc(SIZE, 0x5a);
  const ranges = [];
  const server = createServer((req, res) => {
    const head = {
      "Accept-Ranges": "bytes",
      "Content-Type": "application/octet-stream",
      "Content-Disposition": 'attachment; filename="dinamik.bin"',
    };
    const m = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range || "");
    if (!m) {
      res.writeHead(200, { ...head, "Content-Length": SIZE });
      if (req.method === "HEAD") { res.end(); return; }
      res.end(body);
      return;
    }
    const start = Number(m[1]);
    const end = m[2] ? Number(m[2]) : SIZE - 1;
    // Yalnizca tam SLOW_START'tan baslayan aralik yavas beslenir; boylece
    // bolme sonrasi olusan yeni parca hizli kalir.
    const slow = start === SLOW_START;
    ranges.push({ start, end, at: Date.now(), slow });
    res.writeHead(206, {
      ...head,
      "Content-Range": `bytes ${start}-${end}/${SIZE}`,
      "Content-Length": end - start + 1,
    });
    if (req.method === "HEAD") { res.end(); return; }
    const chunk = slow ? SLOW_CHUNK : FAST_CHUNK;
    const delay = slow ? SLOW_DELAY : FAST_DELAY;
    let off = start;
    const timer = setInterval(() => {
      if (off > end) { clearInterval(timer); res.end(); return; }
      const next = Math.min(off + chunk, end + 1);
      res.write(body.subarray(off, next));
      off = next;
    }, delay);
    res.on("close", () => clearInterval(timer));
  });
  return new Promise((resolve) =>
    server.listen(HTTP_PORT, "127.0.0.1", () => resolve({ server, ranges })),
  );
}

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
  send(object) { this.socket.write(`${JSON.stringify(object)}\n`); }
  waitFor(predicate, timeoutMs, label) {
    const found = this.messages.find(predicate);
    if (found) return Promise.resolve(found);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== waiter);
        reject(new Error(`${label} zaman asimi`));
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
  close() { try { this.socket.destroy(); } catch { /* kapali */ } }
}

async function until(label, timeoutMs, probe, intervalMs = 200) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await probe();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`${label}: zaman asimi`);
    await sleep(intervalMs);
  }
}

async function connectBridge(dataDir) {
  const info = await until("ipc.json", 30000, () => {
    const path = join(dataDir, "ipc.json");
    if (!existsSync(path)) return null;
    try {
      const parsed = JSON.parse(readFileSync(path, "utf8"));
      return parsed.port && parsed.token ? parsed : null;
    } catch { return null; }
  });
  const socket = netConnect({ host: "127.0.0.1", port: info.port });
  await new Promise((resolve, reject) => {
    socket.once("connect", resolve);
    socket.once("error", reject);
  });
  const client = new IpcClient(socket);
  client.send({ type: "hello", token: info.token });
  await client.waitFor((m) => m.type === "ready", 10000, "ready");
  return client;
}

let reqSeq = 0;
async function call(client, op, fields = {}, timeoutMs = 30000) {
  const reqId = `r${++reqSeq}`;
  client.send({ type: op, reqId, ...fields });
  const answer = await client.waitFor((m) => m.reqId === reqId, timeoutMs, `${op} yaniti`);
  if (answer.type === "error") throw new Error(`${op}: ${answer.payload?.message || "hata"}`);
  return answer;
}

const taskList = (client) => call(client, "list").then((a) => a.payload);

function launch(dataDir) {
  const proc = spawn(EXE, [], {
    cwd: join(EXE, ".."),
    env: { ...process.env, SERENE_DATA_DIR: dataDir },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let log = "";
  proc.stdout.on("data", (c) => (log += c.toString()));
  proc.stderr.on("data", (c) => (log += c.toString()));
  proc.on("exit", (code) => (log += `\n[cikis ${code}]`));
  return { proc, log: () => log };
}

const killAll = () =>
  spawnSync("taskkill", ["/F", "/IM", `${IMAGE}.exe`, "/T"], { stdio: "ignore", windowsHide: true });

async function main() {
  if (!existsSync(EXE)) fail("uygulama bulunamadi: " + EXE + " (once `flutter build windows --release`)");
  killAll();
  await sleep(1000);

  const dataDir = join(ROOT, "build", "verify-dyn");
  rmSync(dataDir, { recursive: true, force: true });
  const downloadDir = join(dataDir, "indir");
  mkdirSync(downloadDir, { recursive: true });
  writeFileSync(
    join(dataDir, "settings.json"),
    JSON.stringify(
      {
        downloadDir,
        maxConcurrent: 1,
        connections: CONNECTIONS,
        watchClipboard: false,
        closeToTray: false,
        confirmBrowserDownload: false,
      },
      null,
      2,
    ),
  );
  rmSync(join(dataDir, "ipc.json"), { force: true });

  const http = await startServer();
  const app = launch(dataDir);
  let client = null;
  const report = {};
  const problems = [];

  try {
    client = await connectBridge(dataDir);
    await call(client, "subscribe");
    await client.waitFor((m) => m.type === "subscribed", 10000, "subscribed");

    const ack = await call(client, "enqueue", { url: `http://127.0.0.1:${HTTP_PORT}/big.bin` });
    const id = ack.payload.id;
    report.total = ack.payload.total;
    report.expectedSegments = CONNECTIONS;

    // Bolme olana kadar bekle: gorev listesinde parca sayisi artmali.
    const grown = await until(
      "parca bolunmesi",
      45000,
      async () => {
        const task = (await taskList(client)).find((t) => t.id === id);
        if (!task) return null;
        return (task.segments || []).length > CONNECTIONS ? task : null;
      },
      200,
    );
    report.segmentsAfterSplit = grown.segments.length;
    report.plan = grown.segments.map((s) => [s.start, s.end]);
    if (report.segmentsAfterSplit <= CONNECTIONS) {
      problems.push(`beklenen bolme yok: ${report.segmentsAfterSplit} parca`);
    }

    // Bolme "kalanin yarisi" olmali: kurban SLOW_START'ta kalir ve daralir,
    // taze parca onun bitisiginden baslayip eski sona kadar gider. Kalanin
    // tamamini devretmek (eski davranis) taze parcayi ~4 MiB yapardi.
    const oldEnd = SLOW_START + SEGMENT - 1;
    const victim = grown.segments.find((s) => s.start === SLOW_START);
    const fresh = victim
      ? grown.segments.find((s) => s.start === victim.end + 1)
      : null;
    if (!victim || !fresh) {
      problems.push("bolunen parca cifti planda bulunamadi");
    } else {
      report.split = {
        victim: [victim.start, victim.end],
        fresh: [fresh.start, fresh.end],
      };
      if (victim.end >= oldEnd) problems.push("kurban daralmadi");
      if (fresh.end !== oldEnd) problems.push("taze parca eski sona kadar gitmiyor");
      const freshLength = fresh.end - fresh.start + 1;
      report.freshLength = freshLength;
      if (freshLength > SEGMENT * 0.75) {
        problems.push(
          `bolme yarilamiyor: taze parca ${freshLength} bayt (segment ${SEGMENT} bayt)`,
        );
      }
    }

    // Indirme tamamlanana kadar bekle.
    const done = await until(
      "tamamlama",
      90000,
      async () => {
        const task = (await taskList(client)).find((t) => t.id === id);
        return task && task.status === "completed" ? task : null;
      },
      300,
    );
    report.completed = done.downloaded;

    const file = join(downloadDir, "dinamik.bin");
    const bytes = existsSync(file) ? readFileSync(file) : Buffer.alloc(0);
    report.actualBytes = bytes.length;
    if (bytes.length !== SIZE) {
      problems.push(`eksik dosya: ${bytes.length} / ${SIZE}`);
    } else {
      const expected = Buffer.alloc(SIZE, 0x5a);
      if (!bytes.equals(expected)) problems.push("icerik kaynakla esit degil");
    }

    // Sunucuya sorulan araliklar: yavas baslangic bir kez, sonra bir yeni
    // aralik (bolme) gorulmeli.
    report.requests = http.ranges.length;
    report.slowRequests = http.ranges.filter((r) => r.slow).length;
    const extra = http.ranges.filter((r) => r.start > SLOW_START && r.start < SLOW_START + SEGMENT);
    report.splitRequests = extra.length;
    if (report.splitRequests < 1) {
      problems.push("bolmeden dogan yeni Range istegi gorulmedi");
    }
  } catch (error) {
    problems.push(error.stack || String(error));
    console.log(app.log().slice(-1500));
  } finally {
    if (client) client.close();
    killAll();
    await sleep(600);
    http.server.close();
    rmSync(dataDir, { recursive: true, force: true });
  }

  console.log(JSON.stringify(report, null, 2));
  if (problems.length) fail(problems.join(" | "));
  console.log("BASARILI: yavas parca bolundu, yeni baglantiyla kurtarildi, dosya bozulmadi");
}

main();
