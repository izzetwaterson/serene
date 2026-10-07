// Serene: dinamik bolme + DEVAM dogrulamasi.
//
// check_dynamic.mjs bolunmeyi olcer ama hic DURAKLATMAZ; yani "duraklat, devam
// et, sonra bol" yolunu hicbir kosum denemiyordu. Bu betik tam o yolu hedefler.
//
// Neden onemli: bir parcanin sayaci bir ara yalnizca **bu kosuda** inen baytlari
// sayiyordu; onceden diskte duran baytlar ayri bir skalere yaziliyordu. Devamdan
// sonra bolme o zaman "zaten inmis verinin" icine duserdi: kurbanin dosyasi
// oldugu yerde kalir, taze parca ayni baytlarin uzerine yazar ve birlestirilen
// dosya bozulurdu. Duzeltmeden sonra sayac diskteki baytlarla tohumlanir, yani
// bolme noktasi her zaman gercek inme sinirinin ILERISINDE olmalidir.
//
// Senaryo:
//   1. 32 MiB, 8 baglanti; hepsi esit hizda (bolme tetiklenmez).
//   2. Kurban parca (3.) yeterince bayt indirince DURAKLAT.
//   3. DEVAM et, hemen ardindan kurban araligini yavaslat.
//   4. Motor kurbani bolmeli -- ve nokta, devam anindaki sinirin ilerisinde.
//   5. Kisiti kaldir, indirme bitsin, dosya bayt-bayt kaynakla esit olsun.
//
// Kullanim:
//   cd flutter_app && flutter build windows --debug
//   node scripts/check_dynamic_resume.mjs
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
const HTTP_PORT = 8803;
const SIZE = 32 * 1024 * 1024;
const CONNECTIONS = 8;
const SEGMENT = SIZE / CONNECTIONS; // 4 MiB
const VICTIM_START = 3 * SEGMENT;
const VICTIM_END = VICTIM_START + SEGMENT - 1;
const FAST_CHUNK = 32 * 1024;
const FAST_DELAY = 50; // ~640 KB/s
const SLOW_CHUNK = 4 * 1024;
const SLOW_DELAY = 300; // ~13 KB/s
// Kurban bu kadar indirince duraklatilir. Esik bilerek segmentin YARISINDAN
// buyuk: sayac yalnizca bu kosuyu saysaydi bolme noktasi `start + r + remaining/2`
// yani yaklasik segmentin yarisi olurdu; ancak kurban yaridan fazlasini indirdiyse
// o nokta inmis verinin GERISINE duser ve test hatayi yakalar. Esik yarida
// kalsaydi curuk sayac da "tesadufen" dogru noktayi bulurdu.
const PAUSE_AFTER = (5 * SEGMENT) / 8; // 2,5 MiB (4 MiB'in yarisi = 2 MiB)

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function fail(reason) {
  console.log("BASARISIZ: " + reason);
  process.exit(1);
}

function startServer() {
  const body = Buffer.alloc(SIZE, 0x5a);
  const ranges = [];
  // Kosum boyunca degisen kapi: `on` iken kurban araligindan baslayan istekler
  // cok yavas beslenir. Kapi HER tick okunur, boylece kapaninca acik duran
  // baglanti da hizlanir (yoksa testin sonu asilirdi).
  const throttle = { on: false };
  const inVictimRange = (start) => start >= VICTIM_START && start <= VICTIM_END;

  const server = createServer((req, res) => {
    const head = {
      "Accept-Ranges": "bytes",
      "Content-Type": "application/octet-stream",
      "Content-Disposition": 'attachment; filename="devam.bin"',
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
    ranges.push({ start, end, at: Date.now(), throttled: throttle.on && inVictimRange(start) });
    res.writeHead(206, {
      ...head,
      "Content-Range": `bytes ${start}-${end}/${SIZE}`,
      "Content-Length": end - start + 1,
    });
    if (req.method === "HEAD") { res.end(); return; }

    let off = start;
    let timer = null;
    const pump = () => {
      if (res.destroyed || res.writableEnded) return;
      if (off > end) { res.end(); return; }
      const slow = throttle.on && inVictimRange(start);
      const next = Math.min(off + (slow ? SLOW_CHUNK : FAST_CHUNK), end + 1);
      try {
        res.write(body.subarray(off, next));
      } catch {
        return;
      }
      off = next;
      timer = setTimeout(pump, slow ? SLOW_DELAY : FAST_DELAY);
    };
    timer = setTimeout(pump, 0);
    res.on("close", () => clearTimeout(timer));
  });
  return new Promise((resolve) =>
    server.listen(HTTP_PORT, "127.0.0.1", () => resolve({ server, ranges, throttle })),
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
const findTask = async (client, id) => (await taskList(client)).find((t) => t.id === id);
const victimOf = (task) => (task?.segments || []).find((s) => s.start === VICTIM_START);

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
  if (!existsSync(EXE)) fail("uygulama bulunamadi: " + EXE + " (once `flutter build windows --debug`)");
  killAll();
  await sleep(1000);

  const dataDir = join(ROOT, "build", "verify-dyn-resume");
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

    const ack = await call(client, "enqueue", { url: `http://127.0.0.1:${HTTP_PORT}/devam.bin` });
    const id = ack.payload.id;
    report.total = ack.payload.total;
    report.expectedSegments = CONNECTIONS;

    // 1) Kurban yeterince indirsin; bu sirada kimse bolunmemeli (hepsi esit hizda).
    await until(
      "kurban ilerlemesi",
      45000,
      async () => {
        const task = await findTask(client, id);
        const victim = victimOf(task);
        return victim && victim.downloaded >= PAUSE_AFTER ? task : null;
      },
      150,
    );

    // 2) DURAKLAT.
    await call(client, "pause", { id });
    const paused = await until(
      "duraklama",
      20000,
      async () => {
        const task = await findTask(client, id);
        return task && task.status === "paused" ? task : null;
      },
      100,
    );
    const pre = victimOf(paused)?.downloaded ?? 0;
    report.pausedSegments = paused.segments.length;
    report.pausedAtVictimBytes = pre;
    if (paused.segments.length !== CONNECTIONS) {
      problems.push(
        `duraklatmadan ONCE bolunme olmus: ${paused.segments.length} parca (senaryo bozuldu)`,
      );
    }
    if (pre < PAUSE_AFTER) {
      problems.push(`kurban duraklamada yeterince ilerlememis: ${pre} bayt`);
    }

    // 3) DEVAM + kurban araligini yavaslat.
    await call(client, "resume", { id });
    http.throttle.on = true;

    // 4) Bolme: parca sayisi artmali.
    const grown = await until(
      "devam sonrasi bolme",
      45000,
      async () => {
        const task = await findTask(client, id);
        if (!task) return null;
        return (task.segments || []).length > CONNECTIONS ? task : null;
      },
      150,
    );
    report.segmentsAfterSplit = grown.segments.length;
    report.plan = grown.segments.map((s) => [s.start, s.end]);

    const victim = grown.segments.find((s) => s.start === VICTIM_START);
    const fresh = victim ? grown.segments.find((s) => s.start === victim.end + 1) : null;
    if (!victim || !fresh) {
      problems.push("bolunen parca cifti planda bulunamadi");
    } else {
      const victimLength = victim.end - victim.start + 1;
      report.victim = [victim.start, victim.end];
      report.fresh = [fresh.start, fresh.end];
      report.victimLength = victimLength;
      report.freshLength = fresh.end - fresh.start + 1;

      // Cekirdek iddia: bolme noktasi, devam aninda ZATEN inmiz baytlarin
      // ilerisinde olmali. Sayac yalnizca bu kosuyu saysaydi nokta `pre`nin
      // gerisine duserdi (taze parca inmis verinin ustune binerdi).
      if (fresh.start < VICTIM_START + pre) {
        problems.push(
          `bolme noktasi inmis verinin icinde: ${fresh.start} < ${VICTIM_START + pre} (devam siniri)`,
        );
      }
      if (victimLength < pre) {
        problems.push(`kurban kendi indirdiginden kisa kaldi: ${victimLength} < ${pre}`);
      }
      if (victim.end >= VICTIM_END) problems.push("kurban daralmadi");
      if (fresh.end !== VICTIM_END) problems.push("taze parca eski sona kadar gitmiyor");
    }

    // 5) Kisiti kaldir, indirme bitsin.
    http.throttle.on = false;
    const done = await until(
      "tamamlama",
      150000,
      async () => {
        const task = await findTask(client, id);
        return task && task.status === "completed" ? task : null;
      },
      300,
    );
    report.completed = done.downloaded;

    const file = join(downloadDir, "devam.bin");
    const bytes = existsSync(file) ? readFileSync(file) : Buffer.alloc(0);
    report.actualBytes = bytes.length;
    if (bytes.length !== SIZE) {
      problems.push(`eksik/fazla dosya: ${bytes.length} / ${SIZE}`);
    } else {
      const expected = Buffer.alloc(SIZE, 0x5a);
      if (!bytes.equals(expected)) problems.push("icerik kaynakla esit degil");
    }

    report.requests = http.ranges.length;
    // Devam, kurban araliginin ICINDEN ama basindan DEGIL baslayan bir istek
    // uretmeli; yoksa "devam" hic olmamis demektir.
    report.resumedRequests = http.ranges.filter(
      (r) => r.start > VICTIM_START && r.start <= VICTIM_END,
    ).length;
    if (report.resumedRequests < 1) {
      problems.push("devam eden kurban istegi gorulmedi (resume calismadi?)");
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
  console.log(
    "BASARILI: devam sonrasi bolunen parca inmis verinin ustune binmedi, dosya bozulmadi",
  );
}

main();
