// LGPL ffmpeg indirir ve yalniz `ffmpeg.exe`yi `tools/ffmpeg/`e cikarir.
//
// Neden: DASH'ta ayri inen ses kanalini video ile tek dosyaya mux'lamak ffmpeg
// ister (`core/src/ffmpeg.rs`). Kullaniciya "git ffmpeg kur" dedirtmemek icin
// kurulum paketiyle gelir. Ikili **kaynak agacina girmez** (80 MB): derleme
// zamaninda indirilir, kurulum paketine konur.
//
//   node scripts/fetch_ffmpeg.mjs            # yoksa indir
//   node scripts/fetch_ffmpeg.mjs --force    # yeniden indir
//
// Surum ve SHA-256 sabittir; indirilen arsivin ozeti tutmazsa hicbir sey
// cikarilmaz. Lisans: **LGPL** (GPL bilesen icermeyen BtbN build'i); tam metin
// arsivden `ffmpeg-LICENSE.txt` olarak pakete dahil edilir.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { inflateRawSync } from "node:zlib";

const DIR = resolve(import.meta.dirname, "..");
const OUT_DIR = join(DIR, "tools", "ffmpeg");
const OUT_EXE = join(OUT_DIR, "ffmpeg.exe");
const OUT_LICENSE = join(OUT_DIR, "ffmpeg-LICENSE.txt");

// Sabit build: BtbN FFmpeg-Builds, n8.1 **LGPL** static win64. Arsiv icinde
// `.../bin/ffmpeg.exe` vardir; ffprobe/ffplay alinmaz.
const PIN = {
  tag: "autobuild-2026-10-12-13-12",
  asset: "ffmpeg-n8.1.3-18-g46d899d7a0-win64-lgpl-8.1.zip",
  sha256: "fa6c5563a794a4dc98cb521e7aad1526004149d308f99ff0ca30159b1451c522",
};
const URL = `https://github.com/BtbN/FFmpeg-Builds/releases/download/${PIN.tag}/${PIN.asset}`;

function fail(message) {
  console.log(`BASARISIZ: ${message}`);
  process.exit(1);
}

function sha256(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

async function download(url) {
  const response = await fetch(url, { redirect: "follow" });
  if (!response.ok) fail(`indirilemedi (${response.status}): ${url}`);
  // 160 MB'lik arsiv icin tek parca yeterli.
  return Buffer.from(await response.arrayBuffer());
}

/* ---------- minimum zip okuyucu (tek girdi cikarmak icin) ---------- */

function zipEntries(buffer) {
  // End of central directory: son 22 bayttan geriye imza aranir.
  let eocd = -1;
  for (let i = buffer.length - 22; i >= 0; i--) {
    if (buffer.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) fail("zip: EOCD bulunamadi");

  const count = buffer.readUInt16LE(eocd + 10);
  let offset = buffer.readUInt32LE(eocd + 16);
  const entries = [];
  for (let i = 0; i < count; i++) {
    if (buffer.readUInt32LE(offset) !== 0x02014b50) fail("zip: merkezi dizin bozuk");
    const method = buffer.readUInt16LE(offset + 10);
    const compSize = buffer.readUInt32LE(offset + 20);
    const nameLen = buffer.readUInt16LE(offset + 28);
    const extraLen = buffer.readUInt16LE(offset + 30);
    const commentLen = buffer.readUInt16LE(offset + 32);
    const localOffset = buffer.readUInt32LE(offset + 42);
    const name = buffer.toString("utf8", offset + 46, offset + 46 + nameLen);
    entries.push({ name, method, compSize, localOffset });
    offset += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

function readEntry(buffer, entry) {
  const at = entry.localOffset;
  if (buffer.readUInt32LE(at) !== 0x04034b50) fail(`zip: yerel baslik bozuk (${entry.name})`);
  const nameLen = buffer.readUInt16LE(at + 26);
  const extraLen = buffer.readUInt16LE(at + 28);
  const start = at + 30 + nameLen + extraLen;
  const raw = buffer.subarray(start, start + entry.compSize);
  if (entry.method === 0) return Buffer.from(raw);
  if (entry.method === 8) return inflateRawSync(raw);
  fail(`zip: desteklenmeyen sikistirma yontemi ${entry.method} (${entry.name})`);
}

function pick(entries, test) {
  return entries.find((entry) => test(entry.name.toLowerCase()));
}

/* ---------- ana akis ---------- */

async function main() {
  const force = process.argv.includes("--force");
  if (existsSync(OUT_EXE) && !force) {
    console.log(`ffmpeg hazir: ${OUT_EXE}`);
    return;
  }

  mkdirSync(OUT_DIR, { recursive: true });
  console.log(`indiriliyor: ${PIN.tag}`);
  console.log(`  ${URL}`);

  const archive = await download(URL);
  const digest = sha256(archive);
  if (digest !== PIN.sha256) {
    fail(`SHA-256 tutmadi: beklenen ${PIN.sha256}, gelen ${digest}`);
  }
  console.log(`SHA-256 dogrulandi: ${digest}`);

  const entries = zipEntries(archive);
  const exe = pick(entries, (name) => name.endsWith("/bin/ffmpeg.exe") || name === "bin/ffmpeg.exe");
  if (!exe) fail("arsivde bin/ffmpeg.exe yok");
  const license = pick(entries, (name) => name.endsWith("/license.txt") || name.endsWith("/license"));

  const exeBytes = readEntry(archive, exe);
  writeFileSync(OUT_EXE, exeBytes);
  console.log(`> ${OUT_EXE}  (${(exeBytes.length / 1024 / 1024).toFixed(1)} MB, sha256 ${sha256(exeBytes)})`);

  if (license) {
    writeFileSync(OUT_LICENSE, readEntry(archive, license));
    console.log(`> ${OUT_LICENSE}`);
  } else {
    writeFileSync(
      OUT_LICENSE,
      "FFmpeg is licensed under the GNU LGPL. See https://ffmpeg.org/legal.html\n" +
        "Build: BtbN FFmpeg-Builds (LGPL, win64) - https://github.com/BtbN/FFmpeg-Builds\n",
    );
    console.log(`> ${OUT_LICENSE} (arsivde lisans dosyasi yoktu; kaynak notu yazildi)`);
  }

  console.log("BASARILI: ffmpeg hazir");
}

main().catch((err) => fail(err?.stack || String(err)));
