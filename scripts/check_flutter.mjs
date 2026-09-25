// Serene'in Flutter tek-exe gecisinin uctan uca dogrulamasi.
//
// Eski kosumlar Tauri webview'ini Chrome DevTools Protocol ile suruyordu.
// Flutter'in webview'i yok, ustelik Windows kosucusu sentetik tiklama
// mesajlarini geri ceviriyor; yani tarayiciyi taklit eden bir kosum artik
// mumkun degil. Bu yuzden kosum arayuze dokunmaz: uygulamayi gercekten
// calistirir, tarayici eklentisinin kullandigi yerel kopru uzerinden
// konusturur ve karsiliginda isletim sistemi penceresini Win32'den okur.
//
// Dogrulananlar:
//   1. ipc.json yalitilmis veri klasorune yazilir; kopru ping ile yanitlar
//   2. Ana pencere gercek bir masaustu penceresidir ("Serene" basligi gorunur)
//   3. Ikinci ornek kendi kendine kapanir, ilk pencere yerinde kalir
//   4. kopru -> enqueue: ilerleme olaylari aksin, dosya hedef klasore iner
//   5. capture -> list_captures (ayni adres tekilleisir) -> download_capture
//   6. Tarayici devralmasi onay bekler ve AYRI bir surecte "Indirme Bilgileri"
//      penceresi acilir; karar kopruye yazilinca gorev yeni klasore yeni adla
//      iner, onay penceresi kendiliginden kapanir
//   7. Pencere kapatilinca surec cikar ve ipc.json silinir
//   8. confirmBrowserDownload kapaliysa onay penceresi acilmaz, indirme baslar
//
// Onay kapali akisi ayri bir kalkis istediginden, kapanma yoklamasi (7) o
// yeniden baslatmanin (8) hemen onunda yapilir.
//
// Kullanim:
//   cd flutter_app && flutter build windows --debug
//   node scripts/check_flutter.mjs
//
// Varsayilan Debug derlemesini kullanir; baska bir ikili icin SERENE_APP_EXE
// verilir. Uygulama her acilista native messaging kaydini yanindaki
// serene-nmh.exe'ye cevirdigi icin Release klasorunu hedeflemek kayit
// defterini degistirir; Debug derlemesinde o ikili yoktur, kayda dokunulmaz.
//
// Her sey gecici bir klasorde yasar: kullanicinin %APPDATA%\Serene'i ve
// Indirilenler'i etkilenmez.

import { execFileSync, spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { connect as netConnect } from "node:net";

const ROOT = resolve(import.meta.dirname, "..");
const EXE =
  process.env.SERENE_APP_EXE ||
  join(ROOT, "flutter_app", "build", "windows", "x64", "runner", "Debug", "serene_app.exe");
const IMAGE = "serene_app";
const LIST_WINDOWS = join(ROOT, "scripts", "list_windows.ps1");
const HTTP_PORT = 8802;

const DRIP_CHUNK = 8 * 1024;
const DRIP_DELAY_MS = 120;

const FILES = {
  // Yavas govde: indirme bir ilerleme tikinden (>400 ms) uzun surmeli.
  "/kuyruk.bin": { name: "flutter-kuyruk.bin", body: Buffer.alloc(128 * 1024, 0x41), drip: true },
  "/devralma.bin": { name: "flutter-devralma.bin", body: Buffer.alloc(64 * 1024, 0x42), drip: false },
  "/yakalama.mp4": { name: "flutter-yakalama.mp4", body: Buffer.alloc(48 * 1024, 0x43), drip: false },
};

const urlFor = (path) => `http://127.0.0.1:${HTTP_PORT}${path}`;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function fail(reason) {
  console.log("BASARISIZ: " + reason);
  process.exit(1);
}

/* ---------- yerel test sunucusu ---------- */

function startHttpServer() {
  const server = createServer((req, res) => {
    const entry = FILES[req.url.split("?")[0]];
    if (!entry) {
      res.writeHead(404).end("yok");
      return;
    }
    const { name, body, drip } = entry;
    const total = body.length;
    const range = /bytes=(\d+)-(\d*)/.exec(req.headers.range || "");
    const start = range ? Number(range[1]) : 0;
    const end = range ? (range[2] ? Number(range[2]) : total - 1) : total - 1;

    const headers = {
      "Content-Type": "application/octet-stream",
      "Content-Length": end - start + 1,
      "Accept-Ranges": "bytes",
      "Content-Disposition": `attachment; filename="${name}"`,
    };
    if (range) headers["Content-Range"] = `bytes ${start}-${end}/${total}`;
    res.writeHead(range ? 206 : 200, headers);

    const slice = body.subarray(start, end + 1);
    if (!drip) {
      res.end(slice);
      return;
    }

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

const mainWindowOf = (pid) =>
  openWindows().find((w) => w.pid === pid && w.visible && w.title.includes("Serene")) || null;

const popupWindows = (pid) =>
  openWindows().filter((w) => w.pid !== pid && w.visible && w.title.includes("Bilgileri"));

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
  const reqId = `k${++reqSeq}`;
  client.send({ type: op, reqId, ...fields });
  const answer = await client.waitFor((m) => m.reqId === reqId, timeoutMs, `${op} yaniti`);
  if (answer.type === "error") {
    throw new Error(`${op}: ${answer.payload?.message || "bilinmeyen hata"}`);
  }
  return answer;
}

const taskList = (client) => call(client, "list").then((answer) => answer.payload);

function waitTask(client, id, done, timeoutMs = 90000) {
  return until(
    `gorev ${id}`,
    timeoutMs,
    async () => {
      const task = (await taskList(client)).find((t) => t.id === id);
      return task && done(task) ? task : null;
    },
    400,
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
  await call(client, "subscribe");
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
/// kopru kaydini (`ipc.json`) kendisi siler. Zorla oldurme bu adimi atlar.
function closeGracefully() {
  spawnSync("taskkill", ["/IM", `${IMAGE}.exe`, "/T"], {
    stdio: "ignore",
    windowsHide: true,
  });
}

async function startApp(dataDir) {
  // Onceki ornekten kalan kayit, yeni port yerine olu bir adrese baglanmaya
  // calistirmasin.
  rmSync(join(dataDir, "ipc.json"), { force: true });
  const app = launch(dataDir);
  const started = await connectBridge(dataDir);
  return { app, ...started };
}

/// Kapanma beklendiginde kullanilir: zaman asimi hata degil, sonuc döner.
async function allClosed(timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (openWindows().length === 0) return true;
    if (Date.now() > deadline) return false;
    await sleep(300);
  }
}

function sameBytes(path, expected) {
  if (!existsSync(path)) return false;
  const actual = readFileSync(path);
  return actual.length === expected.length && actual.equals(expected);
}

/* ---------- ana akis ---------- */

const report = {};
const problems = [];

async function main() {
  if (!existsSync(EXE)) fail("uygulama bulunamadi: " + EXE + " (once `flutter build windows --debug`)");
  if (!existsSync(join(EXE, "..", "rust_lib_serene.dll"))) fail("FFI kutuphanesi exe'nin yaninda degil");
  if (openWindows().length) fail("calisan bir serene_app.exe var; kosumdan once onu kapat");

  const dataDir = mkdtempSync(join(tmpdir(), "serene-flutter-"));
  const downloadDir = join(dataDir, "indir");
  const altDir = join(dataDir, "alt-klasor");
  mkdirSync(downloadDir);
  mkdirSync(altDir);

  const writeSettings = (overrides) =>
    writeFileSync(
      join(dataDir, "settings.json"),
      JSON.stringify(
        {
          downloadDir,
          maxConcurrent: 2,
          connections: 2,
          // Kosum sirasinda kullanici bir sey kopyalarsa pano izleyici
          // istenmeyen gorevler acmasin.
          watchClipboard: false,
          closeToTray: false,
          confirmBrowserDownload: true,
          ...overrides,
        },
        null,
        2,
      ),
    );

  writeSettings({});

  const httpServer = await startHttpServer();
  let client = null;
  let app = null;

  try {
    /* 1-2: kalkis, kopru ve ana pencere */
    console.log("baslatiliyor: " + EXE);
    const first = await startApp(dataDir);
    app = first.app;
    client = first.client;
    const mainPid = first.info.pid;

    const pong = await call(client, "ping");
    report.engine = { pid: mainPid, version: pong.payload.version };
    if (pong.payload.pid !== mainPid) {
      problems.push(`ping pid'i ipc.json ile anlasmadi: ${pong.payload.pid} != ${mainPid}`);
    }

    const window = await until("ana pencere", 30000, () => mainWindowOf(mainPid), 400);
    report.mainWindow = window.title;
    console.log(`pencere acildi: "${window.title}" (pid ${mainPid})`);

    /* 3: tek ornek */
    const rival = spawn(EXE, [], {
      cwd: join(EXE, ".."),
      env: { ...process.env, SERENE_DATA_DIR: dataDir },
      stdio: "ignore",
    });
    const exitCode = await until(
      "ikinci orneginden cikmasi",
      30000,
      () => (rival.exitCode === null ? null : { code: rival.exitCode }),
      300,
    );
    report.secondInstance = exitCode;
    if (exitCode.code !== 0) problems.push(`ikinci ornek sifir disinda cikti: ${exitCode.code}`);
    report.windowCountAfterSecond = await until(
      "tek pencereye donus",
      15000,
      () => {
        const alive = openWindows();
        return alive.length === 1 && alive[0].pid === mainPid ? alive.length : null;
      },
      400,
    );

    /* 4: kopru uzerinden indirme */
    const ack = await call(client, "enqueue", { url: urlFor("/kuyruk.bin") });
    const taskId = ack.payload.id;
    await client.waitFor(
      (m) => m.type === "progress" && (m.payload || []).some((tick) => tick.id === taskId),
      30000,
      "ilerleme olayi",
    );
    const finished = await waitTask(client, taskId, (t) => t.status === "completed");
    report.download = { dest: finished.dest, downloaded: finished.downloaded, total: finished.total };
    if (!sameBytes(join(downloadDir, "flutter-kuyruk.bin"), FILES["/kuyruk.bin"].body)) {
      problems.push("flutter-kuyruk.bin hedef klasorde beklenen icerikle bulunamadi");
    }

    /* 5: medya yakalamasi */
    const captureFields = {
      url: urlFor("/yakalama.mp4"),
      filename: "flutter-yakalama.mp4",
      size: FILES["/yakalama.mp4"].body.length,
      contentType: "video/mp4",
      site: "kosum-testi",
    };
    await call(client, "capture", captureFields);
    await call(client, "capture", captureFields); // ayni adres iki kez listeye dusmemeli
    const captures = (await call(client, "list_captures")).payload.filter(
      (item) => item.url === captureFields.url,
    );
    report.captures = captures.length;
    if (captures.length !== 1) problems.push(`yakalama tekillemedi: ${captures.length} kayit`);
    else {
      const capAck = await call(client, "download_capture", { id: captures[0].id });
      const capTask = await waitTask(client, capAck.payload.id, (t) => t.status === "completed");
      report.captureDownload = capTask.dest;
      if (!sameBytes(join(downloadDir, "flutter-yakalama.mp4"), FILES["/yakalama.mp4"].body)) {
        problems.push("yakalanan medya hedef klasorde bulunamadi");
      }
    }

    /* 6: tarayici devralmasi -> ayri onay penceresi -> karar */
    const held = await call(client, "enqueue", { url: urlFor("/devralma.bin"), source: "download" });
    const handoffId = held.payload.id;
    report.handoff = { status: held.payload.status, pending: held.payload.pending };
    if (!held.payload.pending || held.payload.status !== "paused") {
      problems.push("devralma onay bekler halde dogmadi");
    }

    const popup = await until("onay penceresi", 40000, () => popupWindows(mainPid)[0] || null, 400);
    report.handoffWindow = { pid: popup.pid, title: popup.title };
    console.log(`onay penceresi ayri surecte: "${popup.title}" (pid ${popup.pid})`);

    // Penceredeki "Indirmeyi Baslat" ayni iki kopru komutunu yollar; kosum
    // tiklayamadigi icin karari ayni kanaldan veriyor.
    await call(client, "set_dest", { id: handoffId, destDir: altDir, filename: "yeniden-adlandirildi.bin" });
    await call(client, "resume", { id: handoffId });

    const moved = await waitTask(client, handoffId, (t) => t.status === "completed" && !t.pending);
    report.handoffDecision = { dest: moved.dest, filename: moved.filename };
    if (!sameBytes(join(altDir, "yeniden-adlandirildi.bin"), FILES["/devralma.bin"].body)) {
      problems.push("onaylanan devralma yeni klasore yeni adla inmedi");
    }

    try {
      await until("onay penceresinin kapanmasi", 30000, () => (popupWindows(mainPid).length ? null : true), 400);
      report.handoffWindowClosed = true;
    } catch (error) {
      report.leftoverWindows = openWindows();
      throw error;
    }

    /* 7: pencereyi kapat, kopru kaydi silinsin */
    client.close();
    client = null;
    closeGracefully();
    const wentAway = await allClosed(20000);
    report.ipcRemoved = !existsSync(join(dataDir, "ipc.json"));
    if (!wentAway) {
      problems.push("pencere kapatilincaya kadar surec cikmadi");
      killAll();
    } else if (!report.ipcRemoved) {
      problems.push("kapanista ipc.json silinmedi");
    }

    /* 8: onay kapaliyken devralma dogrudan baslar */
    writeSettings({ confirmBrowserDownload: false });
    const second = await startApp(dataDir);
    app = second.app;
    client = second.client;
    report.secondLaunch = { pid: second.info.pid };

    const direct = await call(client, "enqueue", { url: urlFor("/devralma.bin"), source: "download" });
    if (direct.payload.pending) problems.push("onay kapaliyken gorev yine beklemeye alindi");
    const directDone = await waitTask(client, direct.payload.id, (t) => t.status === "completed");
    report.noConfirmFlow = { dest: directDone.dest, pending: directDone.pending };
    const strays = popupWindows(second.info.pid);
    if (strays.length) problems.push(`onay kapaliyken fazladan pencere acildi: ${JSON.stringify(strays)}`);
    else report.noConfirmWindows = openWindows().length;

    client.close();
    client = null;
  } catch (error) {
    problems.push(error.stack || String(error));
    if (app) console.log(app.log().slice(-2000));
  } finally {
    killAll();
    await sleep(800);
    httpServer.close();
    rmSync(dataDir, { recursive: true, force: true });
  }

  console.log(JSON.stringify(report, null, 2));
  if (problems.length) fail(problems.join(" | "));
  console.log(
    "BASARILI: Flutter tek exe'si kopru, pencere, tek ornek, indirme, yakalama ve onay akisiyla calisiyor",
  );
}

main();
