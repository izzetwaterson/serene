// Serene "Yakalananlar" (Faz 7) dogrulamasi.
//
// Gercek uygulama baslatilir, yerel kopruye baglanilir ve eklentinin gonderdigi
// `capture` mesajlari beslenir; kayitlar kopruden ve diskteki captures.json'dan
// okunup karsilastirilir. Webview surulmez.
//
// Dogrulananlar:
//   1. Ayni url iki kez bildirilir; tek kayit kalir ve id degismez (tekillestirme)
//   2. `subscribe` uzerine mevcut liste `captures` olarak itilir
//   3. `download_capture` yerel sunucudan gercek dosyayi indirir; HLS turu
//      tasiyan kayit akis yolundan gecer ve parcalar birlestirilir
//   4. `dismiss_capture` yalnizca verilen kaydi dusurur; olmayan id hata doner
//   5. Kayitlar uygulama yeniden baslatildiktan sonra da durur (captures.json)
//   6. `clear_captures` listeyi bosaltir
//
// Kullanim:
//   cd flutter_app && flutter build windows --debug
//   node scripts/check_captures.mjs
//
// Baska bir derlemeyi denemek icin: SERENE_APP_EXE=...\Serene.exe
// Her sey gecici bir klasorde yasar: kullanicinin %APPDATA%\Serene'i ve
// Indirilenler'i etkilenmez.

import { spawn, spawnSync, execFileSync } from "node:child_process";
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
const HTTP_PORT = 8798;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function fail(reason) {
  console.log("BASARISIZ: " + reason);
  process.exit(1);
}

/* ---------- yerel test sunucusu ---------- */

const FILE_PAYLOAD = Buffer.alloc(96 * 1024, 0x51);
const ts = (fill) => Buffer.alloc(8 * 1024, fill);
const HLS_SEGMENTS = [ts(0x40), ts(0x41), ts(0x42)];
const HLS_EXPECTED = Buffer.concat(HLS_SEGMENTS);
const PLAYLIST = `#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
seg0.ts
#EXTINF:4.0,
seg1.ts
#EXTINF:4.0,
seg2.ts
#EXT-X-ENDLIST
`;

/// Medya dosyasi + tek parcali HLS akisi sunar. Aralik destegi probe'un
/// `Range: bytes=0-0` istegini 206 ile yanitlamasi icin sart.
function startHttpServer() {
  const routes = new Map();
  routes.set("/medya.mp4", {
    type: "video/mp4",
    filename: "yakalama-testi.bin",
    body: FILE_PAYLOAD,
  });
  routes.set("/video/index.m3u8", {
    type: "application/vnd.apple.mpegurl",
    filename: "yakalama-hls.ts",
    body: Buffer.from(PLAYLIST, "utf8"),
  });
  HLS_SEGMENTS.forEach((body, i) =>
    routes.set(`/video/seg${i}.ts`, { type: "video/mp2t", body }),
  );

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
    const headers = { "Content-Type": entry.type, "Accept-Ranges": "bytes" };
    if (entry.filename) {
      headers["Content-Disposition"] = `attachment; filename="${entry.filename}"`;
    }

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
  const reqId = `c${++reqSeq}`;
  client.send({ type: op, reqId, ...fields });
  const answer = await client.waitFor((m) => m.reqId === reqId, timeoutMs, `${op} yaniti`);
  if (answer.type === "error") {
    throw new Error(`${op}: ${answer.payload?.message || "bilinmeyen hata"}`);
  }
  return answer;
}

const listCaptures = (client) => call(client, "list_captures").then((a) => a.payload || []);

async function waitTask(client, id, done, timeoutMs = 90000) {
  return until(
    `gorev ${id}`,
    timeoutMs,
    async () => {
      const tasks = await call(client, "list").then((a) => a.payload);
      const task = tasks.find((t) => t.id === id);
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
  const { client, info } = await connectBridge(dataDir);
  client.send({ type: "subscribe" });
  await client.waitFor((m) => m.type === "subscribed", 10000, "subscribed");
  return { app, client, info };
}

/// Indirilen dosyayi diskteki baytlarla karsilastirir.
function verifyFile(task, expected, label, dir, problems, report) {
  report[label] = { dest: task.dest, total: task.total, downloaded: task.downloaded };
  if (!task.dest || !existsSync(task.dest)) {
    problems.push(`${label}: dosya diskte yok (${task.dest})`);
    return;
  }
  if (dir && !String(task.dest).startsWith(dir)) {
    problems.push(`${label}: dosya indirme klasorunun disinda (${task.dest})`);
  }
  const actual = readFileSync(task.dest);
  report[label].actualBytes = actual.length;
  console.log(`${label}: ${actual.length} bayt indi, beklenen ${expected.length}`);
  if (actual.length !== expected.length) {
    problems.push(`${label}: boyut beklenen degil (${actual.length} != ${expected.length})`);
  } else if (!actual.equals(expected)) {
    problems.push(`${label}: icerik beklenenle ayni degil`);
  }
}

/* ---------- ana akis ---------- */

const report = {};
const problems = [];

async function main() {
  if (!existsSync(EXE)) fail("uygulama bulunamadi: " + EXE + " (once `flutter build windows --debug`)");
  if (openWindows().length) fail(`calisan bir ${IMAGE}.exe var; kosumdan once onu kapat`);

  const dataDir = mkdtempSync(join(tmpdir(), "serene-captures-"));
  const downloadDir = join(dataDir, "indir");
  const capturesPath = join(dataDir, "captures.json");
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
  console.log(`indirme klasoru: ${downloadDir}`);

  const httpServer = await startHttpServer();
  let app = null;
  let client = null;

  try {
    /* 0. Kopru ve abonelik */
    const started = await startApp(dataDir);
    app = started.app;
    client = started.client;
    report.ipcPort = started.info.port;
    console.log("kopru hazir, abonelik kuruldu");

    /* 2. Abonelikte mevcut liste itilmeli. */
    const initial = await client.waitFor(
      (m) => m.type === "captures" && !m.reqId && Array.isArray(m.payload),
      8000,
      "abonelik captures",
    );
    report.subscribePush = initial.payload.length;
    console.log(`abonelik push'u: ${initial.payload.length} kayit`);

    /* 1. Ayni url iki kez -> tek kayit, sabit id. */
    const urlFile = `http://127.0.0.1:${HTTP_PORT}/medya.mp4`;
    const ack1 = await call(client, "capture", {
      url: urlFile,
      filename: "medya.mp4",
      size: FILE_PAYLOAD.length,
      contentType: "video/mp4",
      kind: "file",
      site: "127.0.0.1",
    });
    const first = ack1.payload;
    report.first = first;
    console.log(
      `capture c1: id=${first.id}, tur=${first.kind}, ad=${first.filename}, boyut=${first.size}`,
    );
    if (first.url !== urlFile) problems.push(`kayitli url beklenen degil (${first.url})`);
    if (first.kind !== "file") problems.push(`capture turu file degil (${first.kind})`);
    if (first.filename !== "medya.mp4") problems.push("capture adi tasinmadi");
    if (first.size !== FILE_PAYLOAD.length) problems.push("capture boyutu tasinmadi");
    if (first.contentType !== "video/mp4") problems.push("capture contentType tasinmadi");
    if (first.site !== "127.0.0.1") problems.push("capture site tasinmadi");
    if (!(first.createdAt > 0)) problems.push("capture zamani bos");

    // Depo degisti: abonelere tam liste itilmeli.
    const push = await client.waitFor(
      (m) => m.type === "captures" && !m.reqId && (m.payload || []).some((c) => c.url === urlFile),
      8000,
      "captures guncellemesi",
    );
    report.pushAfterCapture = push.payload.length;
    console.log(`yakalama sonrasi push: ${push.payload.length} kayit`);

    const ack2 = await call(client, "capture", {
      url: urlFile,
      filename: "baska-ad.mp4",
      size: 5,
      contentType: "video/mp4",
      kind: "file",
      site: "127.0.0.1",
    });
    const repeat = ack2.payload;
    report.repeat = repeat;
    console.log(`capture c2 (ayni url): id=${repeat.id}, ad=${repeat.filename}`);
    if (repeat.id !== first.id) problems.push("ayni url icin id degisti (tekillestirme yok)");
    if (repeat.filename !== "medya.mp4") problems.push("ayni url mevcut kaydi degistirdi");

    const byUrl = await listCaptures(client);
    report.afterRepeat = byUrl.filter((c) => c.url === urlFile).length;
    console.log(`ayni url iki kez bildirildi, kayit sayisi: ${report.afterRepeat}`);
    if (report.afterRepeat !== 1) {
      problems.push(`ayni url icin ${report.afterRepeat} kayit var (1 olmali)`);
    }

    /* HLS turu kayit; akis yolundan inmesi gerekir. */
    const urlHls = `http://127.0.0.1:${HTTP_PORT}/video/index.m3u8`;
    const ack3 = await call(client, "capture", {
      url: urlHls,
      filename: "video.m3u8",
      size: 0,
      contentType: "application/vnd.apple.mpegurl",
      kind: "hls",
      site: "127.0.0.1",
    });
    const hls = ack3.payload;
    report.hls = hls;
    console.log(`capture c3: id=${hls.id}, tur=${hls.kind}`);
    if (hls.kind !== "hls") problems.push(`HLS kaydinin turu hls degil (${hls.kind})`);

    const listed = await listCaptures(client);
    report.listCount = listed.length;
    console.log(`list_captures: ${listed.length} kayit`);
    if (!listed.some((c) => c.url === urlFile)) problems.push("listede dosya kaydi yok");
    if (!listed.some((c) => c.url === urlHls)) problems.push("listede HLS kaydi yok");

    /* 3. download_capture: dosya turu. */
    const dl1 = await call(client, "download_capture", { id: first.id }, 30000);
    report.downloadFile = { id: dl1.payload.id, kind: dl1.payload.kind, dest: dl1.payload.dest };
    console.log(`indirme basladi: ${dl1.payload.filename} (tur=${dl1.payload.kind})`);
    const done1 = await waitTask(
      client,
      dl1.payload.id,
      (t) => t.status === "completed" || t.status === "failed",
      60000,
    );
    if (done1.status !== "completed") {
      problems.push(`dosya: indirme tamamlanmadi (${done1.status}: ${done1.error})`);
    }
    verifyFile(done1, FILE_PAYLOAD, "dosya", downloadDir, problems, report);

    /* 3b. download_capture: HLS turu akis yolundan iner. */
    const dl2 = await call(client, "download_capture", { id: hls.id }, 30000);
    report.downloadHls = { id: dl2.payload.id, kind: dl2.payload.kind, dest: dl2.payload.dest };
    if (dl2.payload.kind !== "hls") {
      problems.push(`HLS yakalamasi dosya yoluna gitti (tur=${dl2.payload.kind})`);
    }
    const done2 = await waitTask(
      client,
      dl2.payload.id,
      (t) => t.status === "completed" || t.status === "failed",
      60000,
    );
    if (done2.status !== "completed") {
      problems.push(`hls: indirme tamamlanmadi (${done2.status}: ${done2.error})`);
    }
    verifyFile(done2, HLS_EXPECTED, "hls", downloadDir, problems, report);

    /* 4. dismiss_capture yalnizca verilen kaydi siler. */
    await call(client, "dismiss_capture", { id: hls.id });
    const afterDismiss = await listCaptures(client);
    report.afterDismiss = afterDismiss.length;
    console.log(`dismiss sonrasi kayit sayisi: ${afterDismiss.length}`);
    if (afterDismiss.some((c) => c.id === hls.id)) problems.push("dismiss kaydi silmedi");
    if (!afterDismiss.some((c) => c.id === first.id)) {
      problems.push("dismiss ilgisiz kaydi da sildi");
    }
    let missing = false;
    try {
      await call(client, "dismiss_capture", { id: "olmayan-kimlik" });
      missing = true;
    } catch {
      /* beklenen: bilinmeyen id hata doner */
    }
    if (missing) problems.push("olmayan id ile dismiss hata dondurmedi");

    /* 5. Yeniden baslatma: kayitlar diskten geri gelmeli. */
    client.close();
    client = null;
    killAll();
    await sleep(1500);
    rmSync(join(dataDir, "ipc.json"), { force: true });

    if (!existsSync(capturesPath)) problems.push("captures.json yazilmadi");
    else {
      const onDisk = JSON.parse(readFileSync(capturesPath, "utf8"));
      report.onDiskBeforeRestart = onDisk.length;
      console.log(`kapanmadan once captures.json: ${onDisk.length} kayit`);
      if (onDisk.length !== 1) problems.push(`captures.json'da ${onDisk.length} kayit var (1 olmali)`);
    }

    console.log(`yeniden baslatiliyor: ${EXE}`);
    const again = await startApp(dataDir);
    app = again.app;
    client = again.client;
    const list2 = await client
      .waitFor(
        (m) => m.type === "captures" && Array.isArray(m.payload),
        8000,
        "yeniden baslatma push'u",
      )
      .then((m) => m.payload);
    report.afterRestart = list2.length;
    console.log(`yeniden baslatma sonrasi kayit sayisi: ${list2.length}`);
    if (list2.length !== 1) problems.push(`yeniden baslatmada ${list2.length} kayit dondu (1 olmali)`);
    const survivor = list2.find((c) => c.url === urlFile);
    if (!survivor) problems.push("yeniden baslatmada dosya kaydi kayboldu");
    else if (survivor.id !== first.id) problems.push("yeniden baslatmada id degisti");
    if (list2.some((c) => c.url === urlHls)) problems.push("dismiss edilen kayit geri geldi");

    /* 6. clear_captures: geriye kayit kalmaz (sonraki kosu temiz baslar). */
    const beforeClear = (await listCaptures(client)).length;
    await call(client, "clear_captures");
    const afterClear = (await listCaptures(client)).length;
    report.beforeClear = beforeClear;
    report.afterClear = afterClear;
    console.log(`clear_captures: ${beforeClear} kayit vardi, kalan ${afterClear}`);
    if (beforeClear !== 1) problems.push(`clear oncesi ${beforeClear} kayit vardi (1 beklenirdi)`);
    if (afterClear !== 0) problems.push("clear_captures sonrasi liste bos degil");

    client.close();
    client = null;
  } catch (error) {
    problems.push(error.stack || String(error));
    if (app) console.log(app.log().slice(-2000));
  } finally {
    if (client) client.close();
    killAll();
    await sleep(600);
    httpServer.close();
    rmSync(dataDir, { recursive: true, force: true });
  }

  console.log(JSON.stringify(report, null, 2));
  if (problems.length) fail(problems.join(" | "));
  console.log(
    "BASARILI: yakalananlar tekillestirme, liste itme, indirme (dosya + HLS), silme ve kalicilik dogrulandi",
  );
}

main();
