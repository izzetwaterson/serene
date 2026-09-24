// Serene "Yakalananlar" (Faz 7) dogrulamasi.
//
// Gercek uygulama baslatilir, yerel kopruye baglanilir ve eklentinin gonderdigi
// `capture` mesajlari beslenir; kayitlar kopruden, Tauri komutlarindan ve
// diskteki captures.json'dan okunup karsilastirilir.
//
// Dogrulananlar:
//   1. Ayni url iki kez bildirilir; tek kayit kalir ve id degismez (tekillestirme)
//   2. `subscribe` uzerine mevcut liste `captures` olarak itilir
//   3. `list_captures` mesaji ve Tauri komutu kayitlari ayni sekilde doner
//   4. `download_capture` yerel sunucudan gercek dosyayi indirir; HLS turu
//      tasiyan kayit akis yolundan gecer ve parcalar birlestirilir
//   5. `dismiss_capture` kaydi listeden dusurur
//   6. Kayitlar uygulama yeniden baslatildiktan sonra da durur (captures.json)
//   7. `clear_captures` listeyi bosaltir
//
// Kullanim: node scripts/check_captures.mjs

import { execSync, spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { connect as netConnect } from "node:net";
import { createServer } from "node:http";

const EXE = "C:\\Users\\izzet\\Desktop\\serene\\src-tauri\\target\\debug\\serene.exe";
const CWD = "C:\\Users\\izzet\\Desktop\\serene\\src-tauri";
const IPC_PATH = join(process.env.APPDATA, "Serene", "ipc.json");
const CAPTURES_PATH = join(process.env.APPDATA, "Serene", "captures.json");
const PORT = Number(process.env.SERENE_CDP_PORT || 9338);
const HTTP_PORT = 8798;

/// Test ciktilari indirme klasorune bu onekle duser; temizlikte yalnizca bu
/// kalip silinir (kullanicinin kendi indirmelerine dokunulmaz).
const OUTPUT_PATTERN = /^yakalama-(testi\.bin|hls( \(\d+\))?\.ts)$/;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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
    routes.set(`/video/seg${i}.ts`, { type: "video/mp2t", body })
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

  close() {
    try {
      this.socket.close();
    } catch {
      /* kapali */
    }
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

/// Tauri komutunu arayuz uzerinden cagirir.
async function invoke(cdp, command, args = {}) {
  return cdp.evaluate(
    `(async () => await window.__TAURI__.core.invoke(${JSON.stringify(
      command
    )}, ${JSON.stringify(args)}))()`,
    true
  );
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

/* ---------- uygulama yasam dongusu ---------- */

function killSerene() {
  // Bayat bir ornek varsa tek ornek kilidi yuzunden yeni ornek hemen kapanir;
  // bu yuzden her kosu temiz bir sureçle baslar.
  try {
    execSync('taskkill /F /IM serene.exe /T', { stdio: "ignore", windowsHide: true });
  } catch {
    /* calisan ornek yok */
  }
}

/// Uygulamayi baslatir; log parcaciklari cagiran tarafta toplanir.
function spawnApp(env) {
  const proc = spawn(EXE, [], { cwd: CWD, env, stdio: ["ignore", "pipe", "pipe"] });
  const logs = [];
  proc.stdout.on("data", (chunk) => logs.push(chunk.toString()));
  proc.stderr.on("data", (chunk) => logs.push(chunk.toString()));
  return { proc, logs };
}

async function waitForIpc(timeoutMs = 25000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(IPC_PATH)) {
      try {
        const info = JSON.parse(readFileSync(IPC_PATH, "utf8"));
        if (info.port && info.token) return info;
      } catch {
        /* yazim suruyor */
      }
    }
    await sleep(300);
  }
  throw new Error("ipc.json olusmadi");
}

/// El sikismasini tamamlar ve abonelik kurar.
async function connectBridge(info) {
  const deadline = Date.now() + 15000;
  let client = null;
  while (Date.now() < deadline) {
    try {
      client = await openIpc(info.port);
      break;
    } catch {
      await sleep(300);
    }
  }
  if (!client) throw new Error(`kopruye baglanilamadi (port ${info.port})`);

  client.send({ type: "hello", token: info.token });
  await client.waitFor((m) => m.type === "ready", 10000, "ready");
  client.send({ type: "subscribe" });
  await client.waitFor((m) => m.type === "subscribed", 8000, "subscribed");
  return client;
}

/* ---------- yardimcilar ---------- */

function cleanDownloads(dir = join(process.env.USERPROFILE, "Downloads")) {
  try {
    for (const name of readdirSync(dir)) {
      if (OUTPUT_PATTERN.test(name)) rmSync(join(dir, name), { force: true });
    }
  } catch {
    /* klasor yok */
  }
}

/// `list_captures` mesajini gonderip listeyi bekler.
async function listCaptures(client, reqId) {
  client.send({ type: "list_captures", reqId });
  const message = await client.waitFor(
    (m) => m.type === "captures" && m.reqId === reqId,
    10000,
    `list_captures ${reqId}`
  );
  return message.payload || [];
}

function captureAck(client, reqId) {
  return client.waitFor(
    (m) => (m.type === "ack" || m.type === "error") && m.reqId === reqId,
    15000,
    `capture ${reqId}`
  );
}

/// Yakalanan turdeki gorevin bitmesini bekler; gorev listesi abonelik
/// uzerinden `tasks` olayiyla akar (CDP gerekmez).
async function waitForTask(client, id, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    for (const message of client.messages) {
      if (message.type !== "tasks" || !Array.isArray(message.payload)) continue;
      const task = message.payload.find((item) => item.id === id);
      if (!task) continue;
      last = task;
      if (task.status === "completed" || task.status === "failed") return task;
    }
    await sleep(300);
  }
  throw new Error(`${label}: gorev bitmedi (son durum: ${last?.status})`);
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

async function main() {
  const report = {};
  const problems = [];

  killSerene();
  await sleep(500);
  for (const path of [IPC_PATH, CAPTURES_PATH]) {
    try {
      rmSync(path, { force: true });
    } catch {
      /* yok */
    }
  }
  cleanDownloads();

  const httpServer = await startHttpServer();
  const env = { ...process.env };
  env.WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = `--remote-debugging-port=${PORT}`;

  console.log(`baslatiliyor: ${EXE}`);
  let app = spawnApp(env);
  let cdp = null;
  let client = null;
  let failed = false;

  try {
    /* 0. Kopru ve arayuz ayakta mi */
    const info = await waitForIpc();
    report.ipcPort = info.port;
    cdp = await connectCdp();
    await waitForApp(cdp);
    const settings = await invoke(cdp, "get_settings");
    const downloadsDir = settings.downloadDir;
    report.downloadsDir = downloadsDir;
    console.log(`indirme klasoru: ${downloadsDir}`);

    client = await connectBridge(info);
    console.log("kopru hazir, abonelik kuruldu");

    /* 2. Abonelikte mevcut liste itilmeli. */
    const initial = await client.waitFor(
      (m) => m.type === "captures" && !m.reqId && Array.isArray(m.payload),
      8000,
      "abonelik captures"
    );
    report.subscribePush = initial.payload.length;
    console.log(`abonelik push'u: ${initial.payload.length} kayit`);
    if (!Array.isArray(initial.payload)) problems.push("abonelik push'u liste degil");

    /* 1. Ayni url iki kez -> tek kayit, sabit id. */
    const urlFile = `http://127.0.0.1:${HTTP_PORT}/medya.mp4`;
    client.send({
      type: "capture",
      reqId: "c1",
      url: urlFile,
      filename: "medya.mp4",
      size: FILE_PAYLOAD.length,
      contentType: "video/mp4",
      kind: "file",
      site: "127.0.0.1",
    });
    const ack1 = await captureAck(client, "c1");
    if (ack1.type === "error") throw new Error(`capture c1: ${ack1.payload?.message}`);
    const first = ack1.payload;
    report.first = first;
    console.log(
      `capture c1: id=${first.id}, tur=${first.kind}, ad=${first.filename}, boyut=${first.size}`
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
      "captures guncellemesi"
    );
    report.pushAfterCapture = push.payload.length;
    console.log(`yakalama sonrasi push: ${push.payload.length} kayit`);

    client.send({
      type: "capture",
      reqId: "c2",
      url: urlFile,
      filename: "baska-ad.mp4",
      size: 5,
      contentType: "video/mp4",
      kind: "file",
      site: "127.0.0.1",
    });
    const ack2 = await captureAck(client, "c2");
    if (ack2.type === "error") throw new Error(`capture c2: ${ack2.payload?.message}`);
    const repeat = ack2.payload;
    report.repeat = repeat;
    console.log(`capture c2 (ayni url): id=${repeat.id}, ad=${repeat.filename}`);
    if (repeat.id !== first.id) problems.push("ayni url icin id degisti (tekillestirme yok)");
    if (repeat.filename !== "medya.mp4") problems.push("ayni url mevcut kaydi degistirdi");

    const byUrl = await listCaptures(client, "l1");
    report.afterRepeat = byUrl.filter((c) => c.url === urlFile).length;
    console.log(`ayni url iki kez bildirildi, kayit sayisi: ${report.afterRepeat}`);
    if (report.afterRepeat !== 1) {
      problems.push(`ayni url icin ${report.afterRepeat} kayit var (1 olmali)`);
    }

    /* 4a. HLS turu kayit; akis yolundan inmesi gerekir. */
    const urlHls = `http://127.0.0.1:${HTTP_PORT}/video/index.m3u8`;
    client.send({
      type: "capture",
      reqId: "c3",
      url: urlHls,
      filename: "video.m3u8",
      size: 0,
      contentType: "application/vnd.apple.mpegurl",
      kind: "hls",
      site: "127.0.0.1",
    });
    const ack3 = await captureAck(client, "c3");
    if (ack3.type === "error") throw new Error(`capture c3: ${ack3.payload?.message}`);
    const hls = ack3.payload;
    report.hls = hls;
    console.log(`capture c3: id=${hls.id}, tur=${hls.kind}`);
    if (hls.kind !== "hls") problems.push(`HLS kaydinin turu hls degil (${hls.kind})`);

    /* 3. list_captures hem kopruden hem arayuzden ayni listeyi dondurmeli. */
    const fromBridge = await listCaptures(client, "l2");
    const fromTauri = await invoke(cdp, "list_captures");
    report.listCount = fromBridge.length;
    console.log(`list_captures: kopru=${fromBridge.length}, arayuz=${fromTauri.length}`);
    if (!fromBridge.some((c) => c.url === urlFile)) problems.push("listede dosya kaydi yok");
    if (!fromBridge.some((c) => c.url === urlHls)) problems.push("listede HLS kaydi yok");
    if (fromTauri.length !== fromBridge.length) {
      problems.push(`arayuz listesi koprudan farkli (${fromTauri.length} != ${fromBridge.length})`);
    }

    /* 4. download_capture: dosya turu. */
    client.send({ type: "download_capture", reqId: "d1", id: first.id });
    const dl1 = await client.waitFor(
      (m) => (m.type === "ack" || m.type === "error") && m.reqId === "d1",
      30000,
      "download_capture d1"
    );
    if (dl1.type === "error") throw new Error(`download_capture d1: ${dl1.payload?.message}`);
    report.downloadFile = { id: dl1.payload.id, kind: dl1.payload.kind, dest: dl1.payload.dest };
    console.log(`indirme basladi: ${dl1.payload.filename} (tur=${dl1.payload.kind})`);
    const done1 = await waitForTask(client, dl1.payload.id, 60000, "dosya");
    if (done1.status !== "completed") {
      problems.push(`dosya: indirme tamamlanmadi (${done1.status}: ${done1.error})`);
    }
    verifyFile(done1, FILE_PAYLOAD, "dosya", downloadsDir, problems, report);

    /* 4b. download_capture: HLS turu akis yolundan iner. */
    client.send({ type: "download_capture", reqId: "d2", id: hls.id });
    const dl2 = await client.waitFor(
      (m) => (m.type === "ack" || m.type === "error") && m.reqId === "d2",
      30000,
      "download_capture d2"
    );
    if (dl2.type === "error") throw new Error(`download_capture d2: ${dl2.payload?.message}`);
    report.downloadHls = { id: dl2.payload.id, kind: dl2.payload.kind, dest: dl2.payload.dest };
    if (dl2.payload.kind !== "hls") {
      problems.push(`HLS yakalamasi dosya yoluna gitti (tur=${dl2.payload.kind})`);
    }
    const done2 = await waitForTask(client, dl2.payload.id, 60000, "hls");
    if (done2.status !== "completed") {
      problems.push(`hls: indirme tamamlanmadi (${done2.status}: ${done2.error})`);
    }
    verifyFile(done2, HLS_EXPECTED, "hls", downloadsDir, problems, report);

    /* 5. dismiss_capture yalnizca verilen kaydi siler. */
    await invoke(cdp, "dismiss_capture", { id: hls.id });
    const afterDismiss = await invoke(cdp, "list_captures");
    report.afterDismiss = afterDismiss.length;
    console.log(`dismiss sonrasi kayit sayisi: ${afterDismiss.length}`);
    if (afterDismiss.some((c) => c.id === hls.id)) problems.push("dismiss kaydi silmedi");
    if (!afterDismiss.some((c) => c.id === first.id)) {
      problems.push("dismiss ilgisiz kaydi da sildi");
    }
    let missing = false;
    try {
      await invoke(cdp, "dismiss_capture", { id: "olmayan-kimlik" });
      missing = true;
    } catch {
      /* beklenen: bilinmeyen id hata doner */
    }
    if (missing) problems.push("olmayan id ile dismiss hata dondurmedi");

    /* 6. Yeniden baslatma: kayitlar diskten geri gelmeli. */
    client.close();
    client = null;
    cdp.close();
    cdp = null;
    killSerene();
    await sleep(1500);
    rmSync(IPC_PATH, { force: true });

    if (!existsSync(CAPTURES_PATH)) problems.push("captures.json yazilmadi");
    else {
      const onDisk = JSON.parse(readFileSync(CAPTURES_PATH, "utf8"));
      report.onDiskBeforeRestart = onDisk.length;
      console.log(`kapanmadan once captures.json: ${onDisk.length} kayit`);
      if (onDisk.length !== 1) problems.push(`captures.json'da ${onDisk.length} kayit var (1 olmali)`);
    }

    console.log(`yeniden baslatiliyor: ${EXE}`);
    app = spawnApp(env);
    const info2 = await waitForIpc();
    const client2 = await connectBridge(info2);
    client = client2;
    const list2 = await client2
      .waitFor(
        (m) => m.type === "captures" && Array.isArray(m.payload),
        8000,
        "yeniden baslatma push'u"
      )
      .then((m) => m.payload);
    report.afterRestart = list2.length;
    console.log(`yeniden baslatma sonrasi kayit sayisi: ${list2.length}`);
    if (list2.length !== 1) problems.push(`yeniden baslatmada ${list2.length} kayit dondu (1 olmali)`);
    const survivor = list2.find((c) => c.url === urlFile);
    if (!survivor) problems.push("yeniden baslatmada dosya kaydi kayboldu");
    else if (survivor.id !== first.id) problems.push("yeniden baslatmada id degisti");
    if (list2.some((c) => c.url === urlHls)) problems.push("dismiss edilen kayit geri geldi");

    /* 7. clear_captures: geriye kayit kalmaz (sonraki kosu temiz baslar). */
    cdp = await connectCdp();
    await waitForApp(cdp);
    const cleared = await invoke(cdp, "clear_captures");
    const afterClear = await invoke(cdp, "list_captures");
    report.cleared = cleared;
    report.afterClear = afterClear.length;
    console.log(`clear_captures: ${cleared} kayit silindi, kalan ${afterClear.length}`);
    if (cleared !== 1) problems.push(`clear_captures ${cleared} kayit sildi (1 beklenirdi)`);
    if (afterClear.length !== 0) problems.push("clear_captures sonrasi liste bos degil");

    console.log("");
    console.log(JSON.stringify(report, null, 2));
    console.log("");
    if (problems.length) {
      failed = true;
      console.log(`BASARISIZ: ${problems.join("; ")}`);
    } else {
      console.log(
        "BASARILI: yakalananlar tekillestirme, liste itme, indirme (dosya + HLS), silme ve kalicilik dogrulandi"
      );
    }
  } catch (error) {
    failed = true;
    console.log("");
    console.log(`BASARISIZ: ${error.message}`);
  } finally {
    const log = app?.logs.join("") || "";
    if (log.trim()) {
      console.log("");
      console.log("--- uygulama cikisi ---");
      console.log(log.trim().slice(0, 4000));
    }
    if (client) client.close();
    if (cdp) cdp.close();
    killSerene();
    await sleep(800);
    cleanDownloads();
    httpServer.close();
  }

  process.exit(failed ? 1 : 0);
}

main().catch((error) => {
  console.log(`beklenmeyen hata: ${error.message}`);
  process.exit(2);
});
