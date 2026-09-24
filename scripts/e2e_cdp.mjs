// Serene uctan uca indirme testi.
//
// Klavye odagi / pencere one getirme sorunlarindan bagimsiz calisir: uygulamayi
// WebView2 uzak hata ayiklama portu ile baslatir, URL girisini DOM uzerinden
// doldurur, gercek "Enter" olayini gonderir ve indirmenin tamamlanmasini bekler.
//
// Kullanim: node scripts/e2e_cdp.mjs [url] [bekleme_saniye]

import { spawn } from "node:child_process";
import { existsSync, mkdirSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const EXE = "C:\\Users\\izzet\\Desktop\\serene\\src-tauri\\target\\debug\\serene.exe";
const CWD = "C:\\Users\\izzet\\Desktop\\serene\\src-tauri";
const ARTIFACTS = "C:\\Users\\izzet\\Desktop\\serene\\artifacts";
const PORT = Number(process.env.SERENE_CDP_PORT || 9333);
const URL_ARG = process.argv[2] || "https://proof.ovh.net/files/10Mb.dat";
const WAIT_SECONDS = Number(process.argv[3] || 180);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function human(bytes) {
  if (!bytes) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value.toFixed(index === 0 ? 0 : 1)} ${units[index]}`;
}

async function findTarget() {
  const deadline = Date.now() + 40000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      const targets = await response.json();
      const page = targets.find(
        (item) => item.type === "page" && item.webSocketDebuggerUrl
      );
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
    this.closed = false;

    const failAll = (reason) => {
      this.closed = true;
      for (const entry of this.pending.values()) entry.reject(new Error(reason));
      this.pending.clear();
    };

    socket.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      const entry = this.pending.get(message.id);
      if (!entry) return;
      this.pending.delete(message.id);
      if (message.error) entry.reject(new Error(JSON.stringify(message.error)));
      else entry.resolve(message.result);
    });
    socket.addEventListener("close", () => failAll("CDP baglantisi kapandi"));
    socket.addEventListener("error", () => failAll("CDP soket hatasi"));
  }

  send(method, params = {}) {
    if (this.closed) return Promise.reject(new Error("CDP baglantisi kapali"));
    const id = this.nextId++;
    this.socket.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`${method} zaman asimi`));
      }, 120000);
    });
  }

  async evaluate(expression, awaitPromise = false) {
    const result = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise,
      returnByValue: true,
      userGesture: true,
    });
    if (result.exceptionDetails) {
      const detail =
        result.exceptionDetails.exception?.description ||
        result.exceptionDetails.text;
      throw new Error(`JS hatasi: ${detail}`);
    }
    return result.result.value;
  }
}

async function connect() {
  const target = await findTarget();
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
  const cdp = new Cdp(socket);
  await cdp.send("Runtime.enable");
  await cdp.send("Page.enable");
  return { cdp, socket, target };
}

const TASK_QUERY = `(async () => {
  const tasks = await window.__TAURI__.core.invoke("list_tasks");
  return tasks.map((task) => ({
    id: task.id,
    url: task.url,
    filename: task.filename,
    dest: task.dest,
    total: task.total,
    downloaded: task.downloaded,
    status: task.status,
    error: task.error,
    resumable: task.resumable,
    segments: task.segments ? task.segments.length : 0,
  }));
})()`;

async function readTasks(cdp) {
  return cdp.evaluate(TASK_QUERY, true);
}

// CDP hedefi belge yuklenmeden once de gorunebilir; ayrica Tauri'nin global
// betigi sayfaya sonradan enjekte edilir. Ikisi de hazir olana kadar beklenir.
async function waitForApp(cdp, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await cdp.evaluate(
      `(() => ({
        readyState: document.readyState,
        hasInput: Boolean(document.getElementById("url-input")),
        hasButton: Boolean(document.getElementById("download-btn")),
        hasTauri: Boolean(window.__TAURI__ && window.__TAURI__.core),
        title: document.title,
      }))()`
    );
    if (last.hasInput && last.hasButton && last.hasTauri) return last;
    await sleep(250);
  }
  throw new Error(
    `arayuz hazir olmadi (readyState: ${last?.readyState}, giris: ${last?.hasInput}, tauri: ${last?.hasTauri})`
  );
}

async function main() {
  mkdirSync(ARTIFACTS, { recursive: true });

  const env = { ...process.env };
  env.WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = `--remote-debugging-port=${PORT}`;

  console.log(`baslatiliyor: ${EXE}`);
  const proc = spawn(EXE, [], { cwd: CWD, env, stdio: ["ignore", "pipe", "pipe"] });

  let appLog = "";
  proc.stdout.on("data", (chunk) => {
    appLog += chunk.toString();
  });
  proc.stderr.on("data", (chunk) => {
    appLog += chunk.toString();
  });

  const exitGuard = new Promise((_, reject) => {
    proc.on("exit", (code) => {
      reject(new Error(`uygulama erken kapandi, kod ${code}`));
    });
  });

  let socket;
  let cdp;
  let failed = false;

  try {
    const connection = await Promise.race([connect(), exitGuard]);
    socket = connection.socket;
    cdp = connection.cdp;
    console.log("arayuz baglantisi kuruldu");

    const ready = await waitForApp(cdp);
    console.log(`arayuz hazir (baslik: ${ready.title})`);

    const before = await readTasks(cdp);
    const beforeIds = new Set(before.map((item) => item.id));
    console.log(`baslangicta gorev sayisi: ${before.length}`);

    const trigger = await cdp.evaluate(
      `(() => {
        const input = document.getElementById("url-input");
        input.focus();
        input.value = ${JSON.stringify(URL_ARG)};
        input.dispatchEvent(new Event("input", { bubbles: true }));
        input.dispatchEvent(
          new KeyboardEvent("keydown", {
            key: "Enter",
            code: "Enter",
            bubbles: true,
            cancelable: true,
          })
        );
        return { typed: input.value };
      })()`
    );
    console.log(`URL girildi: ${trigger.typed}`);

    const deadline = Date.now() + WAIT_SECONDS * 1000;
    let task = null;
    let lastLine = "";

    while (Date.now() < deadline) {
      await Promise.race([sleep(1000), exitGuard]);

      const errorText = await cdp.evaluate(
        `(() => {
          const node = document.getElementById("add-error");
          return node && !node.classList.contains("hidden") ? node.textContent : null;
        })()`
      );
      if (errorText) throw new Error(`arayuz hatasi: ${errorText}`);

      // Yalnizca bu kosuda olusan gorev izlenir; onceki kosulardan kalan
      // tamamlanmis gorevler dogrulamayi yanlislikla gecmemeli.
      const tasks = await readTasks(cdp);
      const fresh = tasks.filter((item) => !beforeIds.has(item.id));
      const exact = fresh.find((item) => item.url === URL_ARG);
      if (exact) task = exact;
      else if (fresh.length === 1) task = fresh[0];
      else if (fresh.length > 1) {
        const seen = fresh.map((item) => item.url).join(", ");
        throw new Error(`hangi gorevin bizim oldugu belirsiz: ${seen}`);
      }
      if (!task) continue;

      const line = `${task.status} ${human(task.downloaded)}/${human(task.total)} (${task.segments} parca)`;
      if (line !== lastLine) {
        console.log(`  ${line}`);
        lastLine = line;
      }

      if (task.status === "completed") break;
      if (task.status === "failed") throw new Error(`indirme basarisiz: ${task.error}`);
    }

    if (!task) throw new Error("gorev listeye hic eklenmedi");
    if (task.status !== "completed") {
      throw new Error(`zaman asimi, son durum: ${task.status} ${human(task.downloaded)}`);
    }

    const onDisk = existsSync(task.dest);
    const size = onDisk ? statSync(task.dest).size : -1;

    const shot = await cdp.send("Page.captureScreenshot", { format: "png" });
    const shotPath = join(ARTIFACTS, "serene-download.png");
    writeFileSync(shotPath, Buffer.from(shot.data, "base64"));

    console.log("");
    console.log(`durum     : ${task.status}`);
    console.log(`dosya     : ${task.dest}`);
    console.log(`boyut     : ${human(size)} (gorev kaydi: ${human(task.total)})`);
    console.log(`parca     : ${task.segments}`);
    console.log(`ekran     : ${shotPath}`);

    if (!onDisk) throw new Error("gorev tamamlandi ama dosya diskte yok");
    if (task.total > 0 && size !== task.total) {
      throw new Error(`boyut uyusmuyor: disk ${size}, kayit ${task.total}`);
    }

    console.log("");
    console.log("BASARILI: dosya indirildi ve dogrulandi");
  } catch (error) {
    failed = true;
    console.log("");
    console.log(`BASARISIZ: ${error.message}`);
    try {
      if (cdp) {
        const shot = await cdp.send("Page.captureScreenshot", { format: "png" });
        writeFileSync(
          join(ARTIFACTS, "serene-download.png"),
          Buffer.from(shot.data, "base64")
        );
      }
    } catch {
      /* ekran goruntusu alinamadi */
    }
  } finally {
    if (appLog.trim()) {
      console.log("");
      console.log("--- uygulama cikisi ---");
      console.log(appLog.trim());
    }
    try {
      proc.kill();
    } catch {
      /* zaten kapali */
    }
    await sleep(1500);
    if (socket && socket.readyState === WebSocket.OPEN) socket.close();
  }

  process.exit(failed ? 1 : 0);
}

main().catch((error) => {
  console.log(`beklenmeyen hata: ${error.message}`);
  process.exit(2);
});
