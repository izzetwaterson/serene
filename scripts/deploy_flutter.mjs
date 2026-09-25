// Flutter yayin klasorunu tarayici entegrasyonuna hazir hale getirir.
//
// Eklenti uygulamaya `serene-nmh.exe` uzerinden ulasir ve o ikili her zaman
// uygulama ikilisinin yaninda aranir. Flutter derlemesi yalnizca kendi
// arayuzunu urettigi icin bu adim olmadan yayin klasoru yarim kalir: pencere
// acilir, indirme calisir ama tarayicidan devralma hic gelmez.
//
// Kullanim:
//   node scripts/deploy_flutter.mjs              # Release
//   node scripts/deploy_flutter.mjs --debug      # Debug klasoru
//   node scripts/deploy_flutter.mjs --no-build   # yalnizca kopyala
//   node scripts/deploy_flutter.mjs --register   # tarayici kaydini da cevir
//
// `--register` kullanicinin kayit defterine yazar. Yazmadan once hem manifesti
// hem kaydi yedekler; geri almak icin `--restore <yedek-klasoru>` verilir.

import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const DIR = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const APP = "Serene.exe";
const NMH = "serene-nmh.exe";
const HOST_ID = "com.serene.nmh";

const args = new Set(process.argv.slice(2));
const config = args.has("--debug") ? "Debug" : "Release";
const bundle = join(DIR, "flutter_app", "build", "windows", "x64", "runner", config);
const hostTarget = join(DIR, "native-host", "target", config.toLowerCase());
const manifest = join(process.env.APPDATA ?? "", "Serene", "nmh", `${HOST_ID}.json`);

function run(command, commandArgs, cwd) {
  // Node, kabuk olmadan .bat/.cmd türetmeyi reddediyor; `flutter` da Windows'ta
  // bir betik. Komutlar sabit oldugu icin kabuk kullanmak enjekte edilebilir
  // bir yuzey birakmiyor.
  const line = [command, ...commandArgs].join(" ");
  console.log(`> ${line}`);
  try {
    execFileSync(line, { cwd, stdio: "inherit", windowsHide: true, shell: true });
  } catch (err) {
    if (err?.status === undefined || err?.status === null) fail(`${line} calistirilamadi`);
    fail(`${line} hata ile cikti (${err.status})`);
  }
}

function fail(message) {
  console.log(`BASARISIZ: ${message}`);
  process.exit(1);
}

function registeredPath() {
  if (!existsSync(manifest)) return null;
  try {
    return JSON.parse(readFileSync(manifest, "utf8")).path ?? null;
  } catch {
    return null;
  }
}

function copyHost() {
  const source = join(hostTarget, NMH);
  if (!existsSync(source)) {
    fail(`${source} yok; once derleme yapin (--no-build vermeyin)`);
  }
  copyFileSync(source, join(bundle, NMH));
  return { hostSize: statSync(source).size };
}

function register() {
  const backupDir = mkdtempSync(join(tmpdir(), "serene-register-"));
  const previous = registeredPath();
  writeFileSync(
    join(backupDir, "manifest.json"),
    existsSync(manifest) ? readFileSync(manifest) : "",
  );
  try {
    execFileSync(
      "reg",
      ["export", `HKCU\\Software\\Mozilla\\NativeMessagingHosts\\${HOST_ID}`, "/y", "/fo", "REG",
       join(backupDir, "host.reg")],
      { stdio: "ignore", windowsHide: true },
    );
  } catch {
    /* ilk kurulumda anahtar olmayabilir */
  }
  console.log(`onceki kayit: ${previous ?? "(yok)"}`);
  console.log(`yedek: ${backupDir}`);

  try {
    execFileSync(join(bundle, NMH), ["--register-host"], {
      cwd: bundle,
      stdio: "inherit",
      windowsHide: true,
    });
  } catch {
    fail(`kayit yazilamadi; yedek: ${backupDir}`);
  }

  const now = registeredPath();
  if (now !== join(bundle, NMH)) {
    fail(`kayit dogrulanimadi: manifest ${now ?? "(yok)"}`);
  }
  return { previous, now, backupDir };
}

function restore(backupDir) {
  if (!backupDir || !existsSync(join(backupDir, "manifest.json"))) {
    fail(`yedek bulunamadi: kullanim -> node scripts/deploy_flutter.mjs --restore <yedek-klasoru>`);
  }
  const manifestBackup = readFileSync(join(backupDir, "manifest.json"), "utf8");
  if (manifestBackup.trim()) {
    writeFileSync(manifest, manifestBackup);
  } else if (existsSync(manifest)) {
    rmSync(manifest);
  }
  const reg = join(backupDir, "host.reg");
  if (existsSync(reg)) {
    execFileSync("reg", ["import", reg], { stdio: "inherit", windowsHide: true });
  }
  console.log(`BASARILI: tarayici kaydi geri alindi (${registeredPath()})`);
}

function main() {
  if (args.has("--restore")) return restore(process.argv[3]);

  console.log(`hedef: ${bundle}`);

  if (!args.has("--no-build")) {
    run("flutter", ["build", "windows", `--${config.toLowerCase()}`], join(DIR, "flutter_app"));
    // Host ikilisi kendi paketinde durur; motoru linklemedigi icin kucuk kalir.
    run("cargo", ["build", `--${config.toLowerCase()}`, "--bin", "serene-nmh"], join(DIR, "native-host"));
  }

  if (!existsSync(join(bundle, APP))) {
    fail(`${APP} yok; derlemeyi bekletin`);
  }
  const copied = copyHost();

  const report = {
    config,
    bundle,
    appSize: statSync(join(bundle, APP)).size,
    ...copied,
  };

  if (args.has("--register")) {
    report.registration = register();
  } else {
    report.registration = {
      skipped: true,
      current: registeredPath(),
    };
  }

  console.log(JSON.stringify(report, null, 2));
  console.log(
    args.has("--register")
      ? `BASARILI: ${bundle} tarayiciyla konusur hale geldi`
      : "BASARILI: host ikilisi yayin klasorunde; tarayici kaydi hala eski ornekte (--register ile cevirin)",
  );
}

main();
