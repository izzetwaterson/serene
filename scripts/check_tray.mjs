// Serene tepsi / tek ornek dogrulamasi.
//
// Dogrulananlar:
//   1. closeToTray ayari varsayilan olarak acik ve arayuzden degistirilebiliyor
//   2. Kapat dugmesi sureci oldurmez, pencereyi gizler (indirmeler surer)
//   3. Ikinci kez baslatma yeni surec acmaz; gizli pencereyi geri getirir
//
// Kullanim: node scripts/check_tray.mjs

import { execSync, spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const EXE = "C:\\Users\\izzet\\Desktop\\serene\\src-tauri\\target\\debug\\serene.exe";
const CWD = "C:\\Users\\izzet\\Desktop\\serene\\src-tauri";
const ARTIFACTS = "C:\\Users\\izzet\\Desktop\\serene\\artifacts";
const PORT = Number(process.env.SERENE_CDP_PORT || 9334);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function sereneProcessCount() {
  try {
    const out = execSync('tasklist /FI "IMAGENAME eq serene.exe" /FO CSV /NH', {
      encoding: "utf8",
      windowsHide: true,
    });
    return out
      .split(/\r?\n/)
      .filter((line) => line.toLowerCase().includes("serene.exe")).length;
  } catch {
    return 0;
  }
}

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
      }, 30000);
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
        result.exceptionDetails.exception?.description || result.exceptionDetails.text;
      throw new Error(`JS hatasi: ${detail}`);
    }
    return result.result.value;
  }
}

async function connect(timeoutMs = 40000) {
  const target = await findTarget(timeoutMs);
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
  const cdp = new Cdp(socket);
  await cdp.send("Runtime.enable");
  await cdp.send("Page.enable");
  return { cdp, socket };
}

async function waitForApp(cdp, timeoutMs = 25000) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    try {
      last = await cdp.evaluate(
        `(() => ({
          readyState: document.readyState,
          hasInput: Boolean(document.getElementById("url-input")),
          hasTrayToggle: Boolean(document.getElementById("set-tray")),
          hasTauri: Boolean(window.__TAURI__ && window.__TAURI__.core),
          title: document.title,
        }))()`
      );
    } catch (error) {
      last = { error: error.message };
    }
    if (last && last.hasInput && last.hasTrayToggle && last.hasTauri) return last;
    await sleep(300);
  }
  throw new Error(`arayuz hazir olmadi: ${JSON.stringify(last)}`);
}

const readSettings = `(async () => {
  const s = await window.__TAURI__.core.invoke("get_settings");
  return { downloadDir: s.downloadDir, closeToTray: s.closeToTray };
})()`;

const windowVisible = `(async () => {
  return await window.__TAURI__.window.getCurrentWindow().isVisible();
})()`;

async function main() {
  mkdirSync(ARTIFACTS, { recursive: true });

  const report = {};

  const env = { ...process.env };
  env.WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = `--remote-debugging-port=${PORT}`;

  console.log(`baslatiliyor: ${EXE}`);
  const proc = spawn(EXE, [], { cwd: CWD, env, stdio: ["ignore", "pipe", "pipe"] });

  let appLog = "";
  proc.stdout.on("data", (chunk) => (appLog += chunk.toString()));
  proc.stderr.on("data", (chunk) => (appLog += chunk.toString()));

  let socket;
  let cdp;
  let failed = false;

  try {
    const connection = await connect();
    socket = connection.socket;
    cdp = connection.cdp;

    const ready = await waitForApp(cdp);
    console.log(`arayuz hazir (baslik: ${ready.title})`);

    /* 1. Testin baslangici: ayar acik olsun. Onceki kosudan kalan durum
       kapatma testini yanlis olcume goturur (kapaliyken kapatmak uygulamayi bitirir). */
    report.baseline = await cdp.evaluate(
      `(async () => {
        const s = await window.__TAURI__.core.invoke("get_settings");
        s.closeToTray = true;
        await window.__TAURI__.core.invoke("update_settings", { settings: s });
        const after = await window.__TAURI__.core.invoke("get_settings");
        return { closeToTray: after.closeToTray };
      })()`,
      true
    );
    report.visibleAtStart = await cdp.evaluate(windowVisible, true);
    console.log(`baslangic closeToTray: ${report.baseline.closeToTray}`);
    console.log(`baslangicta pencere gorunur: ${report.visibleAtStart}`);

    /* 2. Arayuz anahtari gercekten ayari suruyor mu? Kapat, kaydet, sonra geri ac. */
    report.toggle = await cdp.evaluate(
      `(async () => {
        const modal = document.getElementById("settings-modal");
        document.getElementById("open-settings").click();
        const toggle = document.getElementById("set-tray");
        const opened = !modal.classList.contains("hidden");
        const checkedWhenOpen = toggle.checked;

        toggle.checked = false;
        document.getElementById("save-settings").click();
        await new Promise((r) => setTimeout(r, 1000));
        const afterOff = (await window.__TAURI__.core.invoke("get_settings")).closeToTray;

        document.getElementById("open-settings").click();
        document.getElementById("set-tray").checked = true;
        document.getElementById("save-settings").click();
        await new Promise((r) => setTimeout(r, 1000));
        const afterOn = (await window.__TAURI__.core.invoke("get_settings")).closeToTray;

        document.getElementById("close-settings").click();
        return { opened, checkedWhenOpen, afterOff, afterOn };
      })()`,
      true
    );
    console.log(
      `ayar penceresi acildi: ${report.toggle.opened}, anahtar kapali gorundu: ${report.toggle.checkedWhenOpen === false}, kapatinca: ${report.toggle.afterOff}, acinca: ${report.toggle.afterOn}`
    );

    /* 3. Kapat dugmesi pencereyi gizler ama sureci yasatir.
       Pencere gizlenirken WebView2 hata ayiklama soketi dusebilir; bu yuzden
       yaniti beklemiyoruz, sonra yeniden baglanip durumu Tauri'ye soruyoruz. */
    try {
      await Promise.race([
        cdp.evaluate(
          `(async () => { await window.__TAURI__.window.getCurrentWindow().close(); return true; })()`,
          true
        ),
        sleep(1500),
      ]);
    } catch {
      /* soket kapandi; beklenen durum */
    }
    await sleep(2500);

    report.processAliveAfterClose = sereneProcessCount();
    console.log(`kapat sonrasi surec sayisi: ${report.processAliveAfterClose}`);

    report.reconnected = false;
    try {
      const again = await connect(15000);
      if (socket && socket.readyState === WebSocket.OPEN) socket.close();
      socket = again.socket;
      cdp = again.cdp;
      report.reconnected = true;
    } catch (error) {
      report.reconnectError = error.message;
    }

    report.hiddenAfterClose = report.reconnected
      ? await cdp.evaluate(
          `(async () => !(await window.__TAURI__.window.getCurrentWindow().isVisible()))()`,
          true
        )
      : null;
    console.log(`kapat sonrasi pencere gizli mi: ${report.hiddenAfterClose}`);

    /* 4. Ikinci baslatma yeni surec acmamali ve gizli pencereyi geri getirmeli */
    const second = spawn(EXE, [], { cwd: CWD, stdio: ["ignore", "pipe", "pipe"] });
    let secondExited = false;
    second.on("exit", () => (secondExited = true));
    await sleep(6000);

    report.processCountAfterSecondLaunch = sereneProcessCount();
    report.secondExited = secondExited;
    console.log(
      `ikinci baslatma sonrasi: surec=${report.processCountAfterSecondLaunch}, ikinci cikti=${secondExited}`
    );

    try {
      second.kill();
    } catch {
      /* zaten kapandi */
    }

    report.visibleAfterSecondLaunch = await cdp.evaluate(
      `(async () => await window.__TAURI__.window.getCurrentWindow().isVisible())()`,
      true
    );
    console.log(`ikinci baslatma sonrasi pencere gorunur mu: ${report.visibleAfterSecondLaunch}`);

    /* 5. Ayari geri dondur ve ekran goruntusu al */
    await cdp.evaluate(
      `(async () => {
        const s = await window.__TAURI__.core.invoke("get_settings");
        s.closeToTray = true;
        await window.__TAURI__.core.invoke("update_settings", { settings: s });
        return true;
      })()`,
      true
    );
    report.restored = await cdp.evaluate(readSettings, true);
    console.log(`geri yuklenen closeToTray: ${report.restored.closeToTray}`);

    const shot = await cdp.send("Page.captureScreenshot", { format: "png" });
    writeFileSync(join(ARTIFACTS, "serene-tray.png"), Buffer.from(shot.data, "base64"));

    console.log("");
    console.log(JSON.stringify(report, null, 2));

    /* --- kararlar --- */
    const problems = [];
    if (report.baseline.closeToTray !== true) {
      problems.push("baslangic closeToTray true yapilamadi");
    }
    if (!report.toggle.opened) problems.push("ayarlar penceresi acilmadi");
    if (report.toggle.checkedWhenOpen !== true) {
      problems.push("anahtar kayitli degere gore isaretlenmedi");
    }
    if (report.toggle.afterOff !== false) {
      problems.push("anahtar kapatilinca closeToTray false olmadi");
    }
    if (report.toggle.afterOn !== true) {
      problems.push("anahtar acilinca closeToTray true olmadi");
    }
    if (report.visibleAtStart !== true) problems.push("pencere baslangicta gorunur degil");
    if (report.processAliveAfterClose !== 1) {
      problems.push(`kapat sonrasi surec sayisi 1 degil (${report.processAliveAfterClose})`);
    }
    if (!report.reconnected) {
      problems.push(`kapat sonrasi CDP yeniden baglanamadi (${report.reconnectError})`);
    }
    if (report.hiddenAfterClose !== true) {
      problems.push(`kapat sonrasi pencere gizlenmedi (${report.hiddenAfterClose})`);
    }
    if (report.processCountAfterSecondLaunch !== 1) {
      problems.push(`ikinci baslatma yeni surec acti (${report.processCountAfterSecondLaunch})`);
    }
    if (!report.secondExited) problems.push("ikinci surec kendini kapatmadi");
    if (report.visibleAfterSecondLaunch !== true) {
      problems.push("ikinci baslatma gizli pencereyi geri getirmedi");
    }
    if (report.restored?.closeToTray !== true) problems.push("ayar geri yuklenemedi");

    console.log("");
    if (problems.length) {
      failed = true;
      console.log(`BASARISIZ: ${problems.join("; ")}`);
    } else {
      console.log("BASARILI: tepsi, kapatma davranisi ve tek ornek korumasi dogrulandi");
    }
  } catch (error) {
    failed = true;
    console.log("");
    console.log(`BASARISIZ: ${error.message}`);
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
    await sleep(1200);
    try {
      execSync('taskkill /F /IM serene.exe /T', { stdio: "ignore", windowsHide: true });
    } catch {
      /* kapanmis */
    }
    if (socket && socket.readyState === WebSocket.OPEN) socket.close();
  }

  process.exit(failed ? 1 : 0);
}

main().catch((error) => {
  console.log(`beklenmeyen hata: ${error.message}`);
  process.exit(2);
});
