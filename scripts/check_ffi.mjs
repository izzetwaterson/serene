// Serene Flutter<->Rust kopru (FFI) dogrulamasi.
//
// Dogrulananlar:
//   1. Derlenmis uygulamanin yaninda rust_lib_serene.dll bulunuyor
//   2. `--selfcheck` pencere acmadan kutuphaneyi yukluyor ve motoru kuruyor
//   3. Asenkron komut (ayar guncelleme) gidip geliyor, cekirdek olayi
//      Dart akisina duser, motor yalitilmis klasore kendi dosyalarini yazar
//
// Kullanim: node scripts/check_ffi.mjs
// Derlemeyi onceden alin: cd flutter_app && flutter build windows --debug

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const ROOT = resolve(import.meta.dirname, "..");
const EXE =
  process.env.SERENE_APP_EXE ||
  join(ROOT, "flutter_app", "build", "windows", "x64", "runner", "Debug", "serene_app.exe");

function fail(reason) {
  console.log("BASARISIZ: " + reason);
  process.exit(1);
}

if (!existsSync(EXE)) fail("uygulama bulunamadi: " + EXE);

const dll = join(EXE, "..", "rust_lib_serene.dll");
if (!existsSync(dll)) fail("FFI kutuphanesi yok: " + dll);

// Motor kullanici listesinde indirme baslatmasin: yoklama bos bir klasorde kosar.
const dataDir = mkdtempSync(join(tmpdir(), "serene-ffi-"));
let run;
try {
  run = spawnSync(EXE, ["--selfcheck"], {
    encoding: "utf8",
    windowsHide: true,
    timeout: 30_000,
    env: { ...process.env, SERENE_DATA_DIR: dataDir },
  });
} finally {
  // ipc.json silinmis olmali; kalan her sey gecici klasorde yok olur.
  rmSync(dataDir, { recursive: true, force: true });
}

if (run.error) fail("calistirilamadi: " + run.error.message);

const out = (run.stdout || "") + (run.stderr || "");
const line = out.split(/\r?\n/).find((l) => l.startsWith("KOPRU "));
if (!line) fail("yoklama satiri yok (cikis kodu " + run.status + "):\n" + out);

const version = /motor=(\S+)/.exec(line)?.[1];
const tasks = /gorev=(\d+)/.exec(line)?.[1];
const concurrent = /eszamanli=(\d+)/.exec(line)?.[1];

if (!version || version === "none") fail("motor surumu bos: " + line);
if (tasks === undefined) fail("gorev listesi gelmedi: " + line);
if (!concurrent || Number(concurrent) < 1) fail("ayar guncelleme asenkron cagrisi basarisiz: " + line);
if (run.status !== 0) fail("cikis kodu sifir degil: " + run.status + " (" + line + ")");

console.log(
  "BASARILI: kopru tek exe icinde calisiyor (motor=" +
    version +
    " gorev=" +
    tasks +
    " eszamanli=" +
    concurrent +
    ")",
);
