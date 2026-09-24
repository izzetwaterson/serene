// Serene Flutter<->Rust kopru (FFI) dogrulamasi.
//
// Dogrulananlar:
//   1. Derlenmis uygulamanin yaninda rust_lib_serene.dll bulunuyor
//   2. `--selfcheck` pencere acmadan Rust kutuphanesini yukluyor
//   3. Senkron cagri (motor surumu) ve Rust'tan Dart'a olay akisi calisiyor
//
// Kullanim: node scripts/check_ffi.mjs
// Derlemeyi onceden alin: cd flutter_app && flutter build windows --debug

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

const ROOT = "C:\\Users\\izzet\\Desktop\\serene";
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

const run = spawnSync(EXE, ["--selfcheck"], { encoding: "utf8", windowsHide: true });
if (run.error) fail("calistirilamadi: " + run.error.message);

const out = (run.stdout || "") + (run.stderr || "");
const line = out.split(/\r?\n/).find((l) => l.startsWith("KOPRU "));
if (!line) fail("yoklama satiri yok (cikis kodu " + run.status + "):\n" + out);

// Ornek motor surumu "0.1.0"; ticks 1,2,3 olmali.
const version = /motor=(\S+)/.exec(line)?.[1];
const ticks = /ticks=\[([^\]]*)\]/.exec(line)?.[1] ?? "";
const tickList = ticks ? ticks.split(",").map((t) => t.trim()) : [];

if (!version || version === "none") fail("motor surumu bos: " + line);
if (tickList.join(",") !== "1,2,3") fail("olay akisi eksik: " + line);
if (run.status !== 0) fail("cikis kodu sifir degil: " + run.status + " (" + line + ")");

console.log("BASARILI: kopru tek exe icinde calisiyor (motor=" + version + " ticks=" + ticks + ")");
