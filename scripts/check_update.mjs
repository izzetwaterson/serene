// Serene surum bildirimi (update notice) dogrulamasi.
//
// Gercek uygulama baslatilir; yerel bir sunucu surum JSON'u dondurur ve
// uygulama `SERENE_UPDATE_URL` ile oraya yonlendirilir. Beklenen: acilista
// **bir kez** yoklama yapmasi (tek okuma; indirme/kurulum YAPILMAZ). Ayrica
// About sekmesi acik baslatilip en iyi cabayla ekran goruntusu alinir; odak
// engellenirse kosum yine de gecer.
//
// Kullanim:
//   cd flutter_app && flutter build windows --debug
//   node scripts/check_update.mjs
//
// Baska bir derlemeyi denemek icin: SERENE_APP_EXE=...\Serene.exe

import { spawn, spawnSync, execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "..");
const EXE =
  process.env.SERENE_APP_EXE ||
  join(ROOT, "flutter_app", "build", "windows", "x64", "runner", "Debug", "Serene.exe");
const IMAGE = "Serene";
const PORT = 8798;
const LATEST = { version: "9.9.9", url: `http://127.0.0.1:${PORT}/serene` };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function fail(reason) {
  console.log("BASARISIZ: " + reason);
  process.exit(1);
}

function runningSerene() {
  const out = execFileSync(
    "tasklist",
    ["/FI", `IMAGENAME eq ${IMAGE}.exe`, "/NH", "/FO", "CSV"],
    { encoding: "utf8", windowsHide: true },
  );
  return out.trim().startsWith('"');
}

function killAll() {
  spawnSync("taskkill", ["/F", "/IM", `${IMAGE}.exe`, "/T"], {
    stdio: "ignore",
    windowsHide: true,
  });
}

async function main() {
  if (!existsSync(EXE)) {
    fail("uygulama yok (once: cd flutter_app && flutter build windows --debug): " + EXE);
  }
  if (runningSerene()) fail(`calisan bir ${IMAGE}.exe var; kosumdan once kapat`);

  const work = join(ROOT, "build", "verify-update");
  const dataDir = join(work, "data");
  const downloadDir = join(work, "indir");
  rmSync(work, { recursive: true, force: true });
  mkdirSync(dataDir, { recursive: true });
  mkdirSync(downloadDir, { recursive: true });

  // Tanitim penceresi (`extensionOfferDone: false`) About sekmesini orter ve
  // asil dogrulanan bildirimi gizler; kapatilmis bir kurulum taklit edilir.
  writeFileSync(
    join(dataDir, "settings.json"),
    JSON.stringify(
      {
        downloadDir,
        maxConcurrent: 2,
        connections: 2,
        watchClipboard: false,
        closeToTray: false,
        confirmBrowserDownload: true,
        extensionOfferDone: true,
      },
      null,
      2,
    ),
  );

  let hits = 0;
  const server = createServer((req, res) => {
    if (req.url === "/latest.json") {
      hits += 1;
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(LATEST));
    } else {
      res.writeHead(404);
      res.end();
    }
  });
  await new Promise((r) => server.listen(PORT, "127.0.0.1", r));
  console.log(`yerel surum sunucusu: http://127.0.0.1:${PORT}/latest.json -> ${LATEST.version}`);

  // `--settings=about`: ayarlar katmani About sekmesi acik baslar; ekran
  // goruntusu bildirimi yakalayabilsin.
  const proc = spawn(EXE, ["--settings=about"], {
    cwd: join(EXE, ".."),
    env: {
      ...process.env,
      SERENE_DATA_DIR: dataDir,
      SERENE_UPDATE_URL: `http://127.0.0.1:${PORT}/latest.json`,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let log = "";
  proc.stdout.on("data", (chunk) => (log += chunk.toString()));
  proc.stderr.on("data", (chunk) => (log += chunk.toString()));
  proc.on("exit", (code) => (log += `\n[cikis ${code}]`));

  const deadline = Date.now() + 20000;
  while (Date.now() < deadline && hits === 0) await sleep(250);

  // Bildirim agdan sonra cizilir; ekran goruntusundan once kisa bir bekleme.
  if (hits > 0) await sleep(1200);

  let shot = null;
  try {
    const out = join(ROOT, "artifacts", "update-notice.png");
    rmSync(out, { force: true });
    execFileSync(
      "powershell",
      [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        join(ROOT, "scripts", "capture_window.ps1"),
        "-ProcessName",
        IMAGE,
        "-Out",
        out,
      ],
      { stdio: "ignore" },
    );
    if (existsSync(out)) shot = out;
  } catch {
    // Odak/one gelme engellendi; gorsel en iyi cabadir, kosumu dusurmez.
  }

  const alive = proc.exitCode === null;
  killAll();
  server.close();
  rmSync(work, { recursive: true, force: true });

  console.log(`yoklama istegi: ${hits}`);
  if (shot) console.log(`gorsel: ${shot}`);
  if (!alive) {
    console.log(log);
    fail(`uygulama beklenmedik sekilde cikti (kod ${proc.exitCode})`);
  }
  if (hits === 0) fail("uygulama acilista surum adresini hic yoklamadi");
  if (hits > 1) console.log(`UYARI: yoklama ${hits} kez yapildi (tek beklenirdi)`);
  console.log("BASARILI: acilista surum bildirimi yoklamasi yapildi");
}

main();
