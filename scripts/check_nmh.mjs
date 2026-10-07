// Serene native messaging host (serene-nmh) dogrulamasi.
//
// Dogrulananlar:
//   1. --register-host: kayit defteri anahtari + host manifesti olusur
//   2. Manifest alanlari Firefox'un bekledigi bicimde (name/type/path/allowed_extensions)
//   3. 4 baytlik yerel bayt sirasi uzunluk oneki ile cerceveleme calisir
//   4. Uygulama kapaliyken nmh onu sessizce baslatir ve kopruye baglanir
//   5. Uygulama zaten acikken nmh ikinci surec baslatmaz
//   6. enqueue komutu nmh uzerinden uctan uca indirme baslatir
//   7. stdin kapaninca nmh cikar
//   8. --unregister-host kaydi siler
//   9. Kosum sonunda kayit geri kurulur: anahtari silen test kullaniciyi
//      kayitsiz birakmasin (kayit yine kosumun derledigi nmh'yi gosterir)
//
// Kullanim: node scripts/check_nmh.mjs

import { execSync, spawn } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

// Baska bir derlemeyi denemek icin: SERENE_TARGET_DIR=...\target\release
// Host, uygulamayi kendi klasorunde aradigi icin test ikilinin YAN YANA oldugu
// yayin klasorunde kosar (`flutter build windows` oraya kopyalar).
const DIR =
  process.env.SERENE_TARGET_DIR ||
  join(resolve(import.meta.dirname, ".."), "flutter_app", "build", "windows", "x64", "runner", "Debug");
const NMH = join(DIR, "serene-nmh.exe");
const EXE = join(DIR, "Serene.exe");
const APPDATA = process.env.APPDATA;
const MANIFEST = join(APPDATA, "Serene", "nmh", "com.serene.nmh.json");
const IPC_PATH = join(APPDATA, "Serene", "ipc.json");
const REG_KEY = "HKCU\\Software\\Mozilla\\NativeMessagingHosts\\com.serene.nmh";
const HTTP_PORT = 8794;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/* ---------- yerel test sunucusu ---------- */

const PAYLOAD = Buffer.alloc(96 * 1024, 0x37);

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
        "Content-Disposition": 'attachment; filename="nmh-testi.bin"',
      });
      res.end(PAYLOAD.subarray(start, end + 1));
      return;
    }

    res.writeHead(200, {
      "Content-Type": "application/octet-stream",
      "Content-Length": total,
      "Accept-Ranges": "bytes",
      "Content-Disposition": 'attachment; filename="nmh-testi.bin"',
    });
    res.end(PAYLOAD);
  });

  return new Promise((resolve) => server.listen(HTTP_PORT, "127.0.0.1", () => resolve(server)));
}

/* ---------- native messaging cerceveleme ---------- */

function frame(object) {
  const payload = Buffer.from(JSON.stringify(object), "utf8");
  const header = Buffer.alloc(4);
  header.writeUInt32LE(payload.length, 0);
  return Buffer.concat([header, payload]);
}

/// Firefox tarafini taklit eden istemci: nmh'yi cocuk surec olarak calistirir.
class FirefoxHost {
  constructor(proc) {
    this.proc = proc;
    this.buffer = Buffer.alloc(0);
    this.messages = [];
    this.waiters = [];
    this.stderr = "";
    this.exited = false;

    proc.stdout.on("data", (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      for (;;) {
        if (this.buffer.length < 4) return;
        const length = this.buffer.readUInt32LE(0);
        if (this.buffer.length < 4 + length) return;
        const body = this.buffer.subarray(4, 4 + length).toString("utf8");
        this.buffer = this.buffer.subarray(4 + length);
        let parsed;
        try {
          parsed = JSON.parse(body);
        } catch {
          continue;
        }
        this.messages.push(parsed);
        for (const waiter of [...this.waiters]) waiter(parsed);
      }
    });

    proc.stderr.on("data", (chunk) => (this.stderr += chunk.toString()));
    proc.on("exit", () => (this.exited = true));
  }

  send(object) {
    this.proc.stdin.write(frame(object));
  }

  waitFor(predicate, timeoutMs = 20000, label = "mesaj") {
    const found = this.messages.find(predicate);
    if (found) return Promise.resolve(found);

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== waiter);
        reject(
          new Error(
            `${label} zaman asimi. Gelenler: ${JSON.stringify(this.messages.slice(-5))}`
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

  async waitForExit(timeoutMs = 10000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (this.exited) return true;
      await sleep(100);
    }
    return false;
  }

  close() {
    try {
      this.proc.stdin.end();
    } catch {
      /* kapali */
    }
    try {
      this.proc.kill();
    } catch {
      /* kapali */
    }
  }
}

function spawnHost() {
  const proc = spawn(NMH, [], { stdio: ["pipe", "pipe", "pipe"] });
  return new FirefoxHost(proc);
}

function processCount(name) {
  try {
    const out = execSync(`tasklist /FI "IMAGENAME eq ${name}" /FO CSV /NH`, {
      encoding: "utf8",
      windowsHide: true,
    });
    return out
      .split(/\r?\n/)
      .filter((line) => line.toLowerCase().includes(name.toLowerCase())).length;
  } catch {
    return 0;
  }
}

function killAll() {
  for (const name of ["Serene.exe", "serene-nmh.exe"]) {
    try {
      execSync(`taskkill /F /IM ${name} /T`, { stdio: "ignore", windowsHide: true });
    } catch {
      /* calismyor */
    }
  }
}

function registryValue() {
  try {
    const out = execSync(`reg query "${REG_KEY}" /ve`, {
      encoding: "utf8",
      windowsHide: true,
      stdio: ["ignore", "pipe", "ignore"],
    });
    const match = /REG_SZ\s+(.+)/.exec(out);
    return match ? match[1].trim() : null;
  } catch {
    return null;
  }
}

/* ---------- ana akis ---------- */

async function main() {
  const report = {};
  const problems = [];
  let failed = false;

  if (!existsSync(NMH)) {
    console.log(`BASARISIZ: ${NMH} yok; once \`flutter build windows --debug\` calistirin`);
    process.exit(1);
  }

  killAll();
  await sleep(1000);

  const httpServer = await startHttpServer();

  try {
    /* 1-2. Kayit ve manifest */
    const reg = spawn(NMH, ["--register-host"], { stdio: ["ignore", "pipe", "pipe"] });
    let regOut = "";
    reg.stdout.on("data", (c) => (regOut += c.toString()));
    reg.stderr.on("data", (c) => (regOut += c.toString()));
    const regCode = await new Promise((resolve) => reg.on("exit", resolve));

    report.register = { exitCode: regCode, output: regOut.trim() };
    console.log(`--register-host: cikis=${regCode}, cikti="${regOut.trim()}"`);
    if (regCode !== 0) problems.push(`--register-host basarisiz (cikis ${regCode})`);

    report.registryValue = registryValue();
    console.log(`kayit defteri: ${report.registryValue}`);
    if (!report.registryValue) problems.push("kayit defteri anahtari yazilmadi");
    if (report.registryValue !== MANIFEST) {
      problems.push(`kayit defteri yolu manifest yoluyla ayni degil`);
    }

    if (!existsSync(MANIFEST)) throw new Error(`manifest olusmadi: ${MANIFEST}`);
    const manifest = JSON.parse(readFileSync(MANIFEST, "utf8"));
    report.manifest = manifest;
    console.log(`manifest: name=${manifest.name}, type=${manifest.type}`);
    console.log(`  path=${manifest.path}`);
    console.log(`  allowed_extensions=${JSON.stringify(manifest.allowed_extensions)}`);

    if (manifest.name !== "com.serene.nmh") problems.push("manifest name yanlis");
    if (manifest.type !== "stdio") problems.push("manifest type 'stdio' degil");
    if (manifest.path !== NMH) problems.push(`manifest path yanlis: ${manifest.path}`);
    if (!manifest.path.toLowerCase().endsWith("serene-nmh.exe")) {
      problems.push("manifest path serene-nmh.exe'yi gostermiyor");
    }
    if (!Array.isArray(manifest.allowed_extensions) || !manifest.allowed_extensions.length) {
      problems.push("manifest allowed_extensions bos");
    }

    /* 3-4. Uygulama kapaliyken cerceveleme + sessiz baslatma */
    report.exeRunningBefore = processCount("Serene.exe");
    console.log(`test oncesi Serene.exe sayisi: ${report.exeRunningBefore}`);
    if (report.exeRunningBefore !== 0) problems.push("test basinda Serene.exe zaten calisiyor");

    const host = spawnHost();
    const startedAt = Date.now();
    host.send({ type: "ping" });

    const pong = await host.waitFor((m) => m.type === "pong", 40000, "pong");
    report.autostartMs = Date.now() - startedAt;
    report.pong = pong.payload;
    console.log(
      `pong ${report.autostartMs} ms icinde geldi: pid=${pong.payload.pid}, surum=${pong.payload.version}`
    );

    report.exeRunningAfter = processCount("Serene.exe");
    report.ipcExists = existsSync(IPC_PATH);
    console.log(
      `otomatik baslatma: Serene.exe=${report.exeRunningAfter}, ipc.json=${report.ipcExists}`
    );
    if (report.exeRunningAfter !== 1) {
      problems.push(`nmh uygulamayi baslatmadi (Serene.exe=${report.exeRunningAfter})`);
    }
    if (!report.ipcExists) problems.push("otomatik baslatma sonrasi ipc.json yok");

    const ipc = JSON.parse(readFileSync(IPC_PATH, "utf8"));
    if (ipc.pid !== pong.payload.pid) {
      problems.push("pong pid'i ipc.json pid'i ile ayni degil");
    }

    /* 5. Ikinci nmh ikinci uygulama baslatmamali */
    const host2 = spawnHost();
    host2.send({ type: "ping" });
    const pong2 = await host2.waitFor((m) => m.type === "pong", 20000, "ikinci pong");
    report.secondHostPid = pong2.payload.pid;
    report.exeRunningAfterSecond = processCount("Serene.exe");
    console.log(
      `ikinci nmh: pid=${pong2.payload.pid}, Serene.exe sayisi=${report.exeRunningAfterSecond}`
    );
    if (report.exeRunningAfterSecond !== 1) {
      problems.push(`ikinci nmh yeni surec acti (${report.exeRunningAfterSecond})`);
    }
    if (pong2.payload.pid !== pong.payload.pid) {
      problems.push("ikinci nmh farkli uygulamaya baglandi");
    }
    host2.close();

    /* 6. Uctan uca indirme */
    host.send({ type: "subscribe" });
    await host.waitFor((m) => m.type === "subscribed", 10000, "subscribed");
    console.log("abonelik kuruldu");

    const url = `http://127.0.0.1:${HTTP_PORT}/nmh-testi.bin`;
    host.send({ type: "enqueue", reqId: "n1", url });

    const ack = await host.waitFor((m) => m.type === "ack" && m.reqId === "n1", 30000, "ack");
    report.ack = {
      id: ack.payload.id,
      filename: ack.payload.filename,
      total: ack.payload.total,
    };
    console.log(`ack: ${report.ack.filename}, boyut=${report.ack.total}`);
    if (report.ack.total !== PAYLOAD.length) {
      problems.push(`ack boyutu beklenen degil (${report.ack.total})`);
    }

    /* Indirme tamamlanana kadar tasks olaylarini izle. */
    const finishDeadline = Date.now() + 60000;
    let finalTask = null;
    while (Date.now() < finishDeadline) {
      const tasksEvent = host.messages.filter((m) => m.type === "tasks").pop();
      finalTask = tasksEvent?.payload?.find((task) => task.id === report.ack.id);
      if (finalTask && (finalTask.status === "completed" || finalTask.status === "failed")) break;
      await sleep(500);
    }
    report.finalStatus = finalTask?.status;
    report.finalDownloaded = finalTask?.downloaded;
    console.log(`indirme sonucu: durum=${report.finalStatus}, inen=${report.finalDownloaded}`);
    if (report.finalStatus !== "completed") {
      problems.push(`nmh uzerinden indirme tamamlanmadi (${report.finalStatus})`);
    }
    if (report.finalDownloaded !== PAYLOAD.length) {
      problems.push(`inen bayt beklenen degil (${report.finalDownloaded})`);
    }

    /* 7. stdin kapaninca nmh cikar */
    host.proc.stdin.end();
    report.hostExited = await host.waitForExit(12000);
    console.log(`stdin kapaninca nmh cikti: ${report.hostExited}`);
    if (!report.hostExited) problems.push("stdin kapaninca nmh cikmadi");
    if (host.stderr.trim()) {
      report.hostStderr = host.stderr.trim();
      console.log(`nmh stderr: ${report.hostStderr}`);
    }

    killAll();
    await sleep(1200);

    /* 8. Kayit silme */
    const unreg = spawn(NMH, ["--unregister-host"], { stdio: ["ignore", "pipe", "pipe"] });
    let unregOut = "";
    unreg.stdout.on("data", (c) => (unregOut += c.toString()));
    unreg.stderr.on("data", (c) => (unregOut += c.toString()));
    const unregCode = await new Promise((resolve) => unreg.on("exit", resolve));
    report.unregister = { exitCode: unregCode, output: unregOut.trim() };
    console.log(`--unregister-host: cikis=${unregCode}, cikti="${unregOut.trim()}"`);
    if (unregCode !== 0) problems.push(`--unregister-host basarisiz (cikis ${unregCode})`);

    report.registryAfterUnregister = registryValue();
    report.manifestAfterUnregister = existsSync(MANIFEST);
    console.log(
      `silme sonrasi: kayit=${report.registryAfterUnregister}, manifest var mi=${report.manifestAfterUnregister}`
    );
    if (report.registryAfterUnregister !== null) {
      problems.push("kayit defteri anahtari silinmedi");
    }
    if (report.manifestAfterUnregister) problems.push("manifest dosyasi silinmedi");

    /* 9. Kaydi geri kur: kosum anahtari sildi, onceki duruma don. */
    const restore = spawn(NMH, ["--register-host"], { stdio: ["ignore", "pipe", "pipe"] });
    let restoreOut = "";
    restore.stdout.on("data", (c) => (restoreOut += c.toString()));
    restore.stderr.on("data", (c) => (restoreOut += c.toString()));
    const restoreCode = await new Promise((resolve) => restore.on("exit", resolve));
    report.registryRestored = registryValue();
    console.log(`kayit geri kuruldu: ${report.registryRestored} (cikis ${restoreCode})`);
    if (restoreCode !== 0 || report.registryRestored !== MANIFEST) {
      problems.push(`kayit geri kurulamadi: ${restoreOut.trim() || "(cikti yok)"}`);
    }

    console.log("");
    console.log(JSON.stringify(report, null, 2));
    console.log("");
    if (problems.length) {
      failed = true;
      console.log(`BASARISIZ: ${problems.join("; ")}`);
    } else {
      console.log("BASARILI: native messaging kaydi, cerceveleme ve sessiz baslatma dogrulandi");
    }
  } catch (error) {
    failed = true;
    console.log("");
    console.log(`BASARISIZ: ${error.message}`);
  } finally {
    killAll();
    await sleep(500);
    try {
      execSync('del /q "%USERPROFILE%\\Downloads\\nmh-testi.bin"', {
        stdio: "ignore",
        windowsHide: true,
      });
    } catch {
      /* yok */
    }
    httpServer.close();
  }

  process.exit(failed ? 1 : 0);
}

main().catch((error) => {
  console.log(`beklenmeyen hata: ${error.message}`);
  process.exit(2);
});
