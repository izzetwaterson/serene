// Serene yayin akisi: tek komut, dort cikti.
//
//   node scripts/release.mjs
//
// Adimlar (ilk hatta durur):
//   1. surumu `flutter_app/pubspec.yaml`den okur (tek kaynak)
//   2. `flutter build windows --release`      -> uygulama + gomulu motor
//      (ayni adimda kaynak surumu tutarliligi denetlenir)
//   3. `cargo build --release --bin serene-nmh` -> tarayici koprusu
//   4. temiz yayin klasoru: `build/release/Serene-<surum>/` (uygulama,
//      kopru ve `extension\` klasoru birlikte)
//   5. ozel Flutter kurulum uygulamasi (`installer_app/`) derlenir; `makensis`
//      yalniz tek-dosya tasiyici (`installer/bootstrap.nsi`) olarak
//      kullanilir        -> `dist/Serene-Setup-<surum>.exe`
//   6. `dist/Serene-<surum>-portable.zip` (kurulum paketi olmadan)
//      + `python scripts/pack_extension.py` -> `dist/` altina eklenti paketleri
//   7. `dist/SURUM-NOTU-<surum>.md` iskeleti
//   8. ozet (dosya boyutlariyla)
//
// Elle yapilan `deploy_flutter.mjs` bu akisi yalnizca gelistirme icindir
// (hazir derlemeyi kopyalar, `--register` ile tarayici kaydini cevirir);
// dagitim gerektiren her sey buradan gecer.

import { execFileSync } from "node:child_process";
import {
  copyFileSync,
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { deflateRawSync } from "node:zlib";
import { join, resolve } from "node:path";

const DIR = resolve(import.meta.dirname, "..");
const DIST = join(DIR, "dist");
const STAGE_ROOT = join(DIR, "build", "release");
const NSI = join(DIR, "installer", "bootstrap.nsi");
const SETUP_APP = join(DIR, "installer_app");
const SETUP_UI = join(SETUP_APP, "build", "windows", "x64", "runner", "Release");
const APP = "Serene.exe";
const NMH = "serene-nmh.exe";
const MAKENSIS_DEFAULT = "C:\\Program Files (x86)\\NSIS\\makensis.exe";

/* ---------- yardimcilar ---------- */

function fail(message) {
  console.log(`BASARISIZ: ${message}`);
  process.exit(1);
}

function step(text) {
  console.log(`\n== ${text}`);
}

function run(command, commandArgs, cwd) {
  // Node, kabuk olmadan .bat/.cmd turetmeyi reddediyor; flutter ve python
  // Windows'ta betik. Komutlar sabit oldugu icin kabuk kullanmak enjekte
  // edilebilir bir yuzey birakmiyor (deploy_flutter.mjs ile ayni gerekce).
  // Kabuk yolu bosluk iceren argumanlari oldugu gibi yemez ("C:\Program
  // Files" bolunur), o yuzden tirnak ekleniyor.
  const quote = (part) => (/[\s"]/.test(part) ? `"${part}"` : part);
  const line = [command, ...commandArgs].map(quote).join(" ");
  console.log(`> ${line}`);
  try {
    execFileSync(line, { cwd, stdio: "inherit", windowsHide: true, shell: true });
  } catch (err) {
    if (err?.status === undefined || err?.status === null) fail(`${line} calistirilamadi`);
    fail(`${line} hata ile cikti (${err.status})`);
  }
}

function mb(path) {
  const bytes = statSync(path).size;
  return bytes < 1024 * 1024 ? `${(bytes / 1024).toFixed(0)} KB` : `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

/* ---------- surum ---------- */

// `pubspec.yaml`daki tek satir. Build number (`1.0.0+1`) kabul edilmez:
// `windows/CMakeLists.txt` bunu dogrudan VERSION_AS_STRING yapip gecersiz bir
// kaynak surumu uretiyor (docs/planning/STATUS.md 3.2).
function readVersion() {
  const pubspec = readFileSync(join(DIR, "flutter_app", "pubspec.yaml"), "utf8");
  const match = /^version:\s*(\S+)\s*$/m.exec(pubspec);
  if (!match) fail("pubspec.yaml icinde `version:` satiri yok");
  const version = match[1];
  if (version.includes("+")) {
    fail(`pubspec.yaml surumu "${version}" build number iceriyor; Windows kaynak surumu bozulur`);
  }
  if (!/^\d+(\.\d+){1,3}$/.test(version)) {
    fail(`pubspec.yaml surumu "${version}" sayisal degil`);
  }
  return version;
}

// `VIProductVersion` dort parca ister: 1.0.0 -> 1.0.0.0
function versionQuad(version) {
  const parts = version.split(".");
  while (parts.length < 4) parts.push("0");
  return parts.slice(0, 4).join(".");
}

// Ucuncu taraf: surum `generated_config.cmake`e girip Runner.rc oradan
// okunuyor. Ikisi ayrilirsa uygulama "Serene 1.0.0" der, kurulum paketi
// "Serene 1.0.1" yazar; sessizce yanlis cikar.
function verifyResourceVersion(version) {
  const config = join(DIR, "flutter_app", "windows", "flutter", "ephemeral", "generated_config.cmake");
  if (!existsSync(config)) {
    console.log(`UYARI: ${config} yok; surum tutarliligi denetlenemedi`);
    return;
  }
  const found = /set\(FLUTTER_VERSION\s+"([^"]+)"/.exec(readFileSync(config, "utf8"));
  if (!found) {
    fail(`generated_config.cmake icinde FLUTTER_VERSION yok`);
  }
  if (found[1] !== version) {
    fail(`surum tutarsiz: pubspec ${version}, generated_config.cmake ${found[1]}`);
  }
  const rc = readFileSync(join(DIR, "flutter_app", "windows", "runner", "Runner.rc"), "utf8");
  for (const key of ["FileVersion", "ProductVersion"]) {
    if (!new RegExp(`VALUE "${key}", VERSION_AS_STRING`).test(rc)) {
      fail(`Runner.rc: ${key} VERSION_AS_STRING okumuyor; kaynak surumu elle yazilmis olabilir`);
    }
  }
  console.log(`surum tutarli: ${version} (pubspec = generated_config = Runner.rc)`);
}

/* ---------- yayin klasoru ---------- */

// Sadece calistirilabilir bir uygulama olusturan dosyalar. Liste acik:
// Flutter surumune yeni bir eklenti dll'i eklenirse buraya girmezse kurulum
// paketi eksik cikar, bu yuzden "klasoru oldugu gibi tasi" degil, "bu dosyalar
// lazim" yaklasimi kullanilir.
//
// Not: Debug klasorunde ayrica `native_assets.json` ve `Serene.pdb` var,
// Release klasorunde yoklar. `native_assets.json` Dart'in yalnizca gelistirme
// derlemesinde urettigi varlik bildirimidir; Flutter tarafini ilgilendiren
// esi `data\flutter_assets\NativeAssetsManifest.json` zaten data icinde gelir.
// `.pdb` hata ayiklama semboludur, dagitilmaz.
const REQUIRED_FILES = [
  APP,                       // Flutter kabugu
  "rust_lib_serene.dll",     // gomulu indirme motoru (flutter_rust_bridge)
  "flutter_windows.dll",     // Flutter kosucusu
  "cnativeapi.dll",          // window_manager eklentisinin C++ yardimcisi
  "window_manager_plugin.dll",
  "screen_retriever_windows_plugin.dll",
  NMH,                       // tarayici koprusu (motoru linklemez)
];
// data\ = AOT kodu (app.so), ICU verisi, yazi tipleri, golgeler.
const REQUIRED_DIRS = ["data"];

// Butun klasoru tasiyoruz; gelistirme artiklari (`*.pdb`, `*.ilk`) ve
// gizli dosyalar one cikarilir.
const EXCLUDE = new Set([".git", ".vs", "__pycache__"]);
const isJunk = (name) => EXCLUDE.has(name) || name.startsWith(".") || name.endsWith(".pdb") || name.endsWith(".ilk");

function stageRelease(version, bundle, hostExe) {
  const stage = join(STAGE_ROOT, `Serene-${version}`);
  rmSync(stage, { recursive: true, force: true });
  mkdirSync(stage, { recursive: true });

  for (const name of REQUIRED_FILES) {
    // serene-nmh ayri paketten gelir (deploy_flutter.mjs ile ayni yol).
    const source = name === NMH ? hostExe : join(bundle, name);
    if (!existsSync(source)) fail(`yayin dosyasi yok: ${source}`);
    copyFileSync(source, join(stage, name));
  }

  for (const name of REQUIRED_DIRS) {
    if (!existsSync(join(bundle, name))) fail(`yayin klasoru yok: ${join(bundle, name)}`);
    cpSync(join(bundle, name), join(stage, name), {
      recursive: true,
      filter: (src) => !isJunk(src.split("\\").pop()),
    });
  }

  // Tarayici eklentisi pakete dahildir: uygulama ilk acilista bu klasoru
  // gosterir, kullanici gecici eklenti olarak yukler. Klasor yoksa paket
  // eksik cikar; sessizce devam edilmez.
  const extensionDir = join(DIR, "extension");
  if (!existsSync(join(extensionDir, "manifest.json"))) {
    fail(`eklenti klasoru eksik: ${extensionDir}`);
  }
  cpSync(extensionDir, join(stage, "extension"), {
    recursive: true,
    filter: (src) => !isJunk(src.split("\\").pop()),
  });

  // Lisansta dagitimla birlikte gitmek zorunda (MIT) ve kurulum paketinin
  // lisans sayfasi buradan okuyor.
  copyFileSync(join(DIR, "LICENSE"), join(stage, "LICENSE.txt"));
  copyFileSync(join(DIR, "THIRD_PARTY_LICENSES.md"), join(stage, "THIRD_PARTY_LICENSES.md"));

  // Guvenlik agi: gelistirme artiklari hicbir kosulda paketlenmemeli.
  const strays = readdirSync(stage).filter((name) => isJunk(name));
  if (strays.length) fail(`yayin klasorunde gelistirme artigi var: ${strays.join(", ")}`);

  return stage;
}

/* ---------- zip (bagimliliksiz) ---------- */

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[i] = c;
  }
  return table;
})();

function crc32(buffer) {
  let c = -1;
  for (let i = 0; i < buffer.length; i++) c = CRC_TABLE[(c ^ buffer[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

function filesUnder(root) {
  const out = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else out.push(full);
    }
  };
  walk(root);
  return out.sort();
}

// Minimum zip yazici. Gerekce: `Compress-Archive` 2 GB dosya sinirinda
// kalir ve PowerShell uzerinden cagrilmak kotu tirnak bir problem; bu yol
// harici arac ve ek bagimlilik istemiyor.
function writeZip(target, files, root) {
  const chunks = [];
  const central = [];
  let offset = 0;
  for (const file of files) {
    const data = readFileSync(file);
    const name = file.slice(root.length + 1).replaceAll("\\", "/");
    const nameBuf = Buffer.from(name, "utf8");
    const deflated = deflateRawSync(data, { level: 9 });
    // Sikistirma kazanc yoksa sakla (kucuk dosyalar icin).
    const useDeflate = deflated.length < data.length;
    const body = useDeflate ? deflated : data;
    const method = useDeflate ? 8 : 0;
    const crc = crc32(data);

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);          // surum
    local.writeUInt16LE(0x0800, 6);      // dosya adlari UTF-8
    local.writeUInt16LE(method, 8);
    // tarih/saat sabit: ayni girdiden ayni zip ciksin
    local.writeUInt16LE(0, 10);
    local.writeUInt16LE(0x21, 12);       // 1.1.1980
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(body.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuf.length, 26);
    chunks.push(local, nameBuf, body);

    const entry = Buffer.alloc(46);
    entry.writeUInt32LE(0x02014b50, 0);
    entry.writeUInt16LE(20, 4);
    entry.writeUInt16LE(20, 6);
    entry.writeUInt16LE(0x0800, 8);
    entry.writeUInt16LE(method, 10);
    entry.writeUInt16LE(0, 12);
    entry.writeUInt16LE(0x21, 14);
    entry.writeUInt32LE(crc, 16);
    entry.writeUInt32LE(body.length, 20);
    entry.writeUInt32LE(data.length, 24);
    entry.writeUInt16LE(nameBuf.length, 28);
    entry.writeUInt32LE(0, 38);          // dis numarasi
    entry.writeUInt32LE(offset, 42);
    central.push(entry, nameBuf);

    offset += local.length + nameBuf.length + body.length;
  }

  const dir = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(files.length, 8);
  end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(dir.length, 12);
  end.writeUInt32LE(offset, 16);
  writeFileSync(target, Buffer.concat([...chunks, dir, end]));
}

/* ---------- surum notu iskeleti ---------- */

function writeReleaseNotes(version) {
  const today = new Date().toISOString().slice(0, 10);
  const text = `# Serene ${version} — Sürüm Notu

Tarih: ${today}

Bu dosya \`node scripts/release.mjs\` tarafından olusturuldu; yayindan once
doldurulmasi gerekir. Turkce yazilir, teknik ayrinti gerekirse ek bolum
eklenebilir.

## Yeni

-

## Duzeltilen

-

## Bilinen Sinirlar

- Kod imzasi yok: Windows SmartScreen "bilinmeyen yayinci" uyarisi verir.
  Kurulumdan once bu uyariyi gorursunuz, "Daha fazla bilgi" > "Yine de
  calistir" demek gerekebilir.
- Tarayici eklentisi Manifest V3 (Firefox). Uygulama ilk acilista \`extension\`
  klasorunu gosterir; eklenti oradan gecici olarak yuklenebilir. AMO paketi
  \`dist\\serene-<surum>.zip\`.

## Yukleme

- Kurulum paketi: \`Serene-Setup-${version}.exe\` (kullanici bazli, yonetici
  hakki istemez)
- Tasinabilir surum: \`Serene-${version}-portable.zip\`
- Tarayici eklentisi pakete dahildir (\`extension\` klasoru); kurulumdan
  sonra uygulama ilk acilista kurulum adimlarini gosterir

## Geri Bildirim

_Bu bolum yayin oncesinde gercek bir adresle doldurulmali (depo henuz
yayinda degil)._

## Kontrol Listesi

- [ ] Kurulum paketi temiz bir makinede kuruldu ve acildi
- [ ] Kaldirma sonrasi indirme listesi korundu
- [ ] Tarayici eklentisi devralma calisiyor
- [ ] \`Surum Notu\` yukarida gercekten yazildi
`;
  const path = join(DIST, `SURUM-NOTU-${version}.md`);
  writeFileSync(path, text, "utf8");
  return path;
}

/* ---------- makensis ---------- */

function findMakensis() {
  const candidates = [process.env.MAKENSIS, MAKENSIS_DEFAULT].filter(Boolean);
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  fail(`makensis bulunamadi; MAKENSIS ortam degiskenini ayarla (${MAKENSIS_DEFAULT})`);
}

function buildInstaller(version, stage, stageBytes) {
  const makensis = findMakensis();
  const icon = join(DIR, "flutter_app", "windows", "runner", "resources", "app_icon.ico");
  if (!existsSync(icon)) fail(`uygulama ikonu yok: ${icon}`);

  // Gorunen her sey Flutter arayuzudur; NSIS yalnizca onu ve yayin klasorunu
  // tek exe icine koyar. Surum Flutter tarafina `--version` ile gecer (tasiyici).
  run("flutter", ["pub", "get"], SETUP_APP);
  run("flutter", ["build", "windows", "--release"], SETUP_APP);
  if (!existsSync(join(SETUP_UI, "SereneSetup.exe"))) fail(`kurulum uygulamasi derlenmedi: ${SETUP_UI}`);
  const out = join(DIST, `Serene-Setup-${version}.exe`);
  rmSync(out, { force: true });
  run(makensis, [
    // BOM'suz kaynak bu bayrak olmadan sistem kod sayfasiyla okunur ve
    // Turkce metinler bozulur.
    "/INPUTCHARSET",
    "UTF8",
    `-DSERENE_VERSION=${version}`,
    `-DSERENE_VERSION_QUAD=${versionQuad(version)}`,
    `-DSERENE_STAGE=${stage}`,
    // Ikon yalnizca tasiyici exe'nin dosya simgesidir.
    `-DSERENE_ICON=${icon}`,
    // Flutter kurulum uygulamasinin Release klasoru (mutlak yol).
    `-DSETUP_UI=${SETUP_UI}`,
    `-DOUTFILE=${out}`,
    NSI,
  ], DIR);
  if (!existsSync(out)) fail(`kurulum paketi uretilmedi: ${out}`);
  return out;
}

/* ---------- eklenti ---------- */

function packExtension() {
  run("python", [join("scripts", "pack_extension.py")], DIR);

  // pack_extension.py ciktisini `artifacts/` altina yazar (dosya onun
  // sahibi; burada yalnizca kopyalanir). Surum ve kimlik eklenti
  // manifestinden gelir, uygulama surumunden degil.
  const meta = JSON.parse(readFileSync(join(DIR, "extension", "manifest.json"), "utf8"));
  const identity = meta?.browser_specific_settings?.gecko?.id;
  if (!identity) fail("extension/manifest.json icinde gecko kimligi yok");
  const names = [`serene-${meta.version}.zip`, `${identity}.xpi`];

  const copied = [];
  for (const name of names) {
    const source = join(DIR, "artifacts", name);
    if (!existsSync(source)) fail(`eklenti paketi uretilmedi: ${source}`);
    const target = join(DIST, name);
    copyFileSync(source, target);
    copied.push(target);
  }
  return { copied, version: meta.version };
}

/* ---------- ana akis ---------- */

function main() {
  step("1/8 surum okunuyor");
  const version = readVersion();
  console.log(`surum: ${version} (kaynak: flutter_app/pubspec.yaml)`);

  // Kurulum/derleme sirasinda calisan bir Serene.exe kendi dosyalari
  // kilitliyor; derleme yarim birakir.
  const running = execFileSync(
    'tasklist /FI "IMAGENAME eq Serene.exe" /NH /FO CSV',
    { encoding: "utf8", windowsHide: true, shell: true },
  ).trim();
  if (running.startsWith('"')) {
    fail("Serene calisiyor; once kapatin (Yonetici Gorevleri > Serene)");
  }

  const bundle = join(DIR, "flutter_app", "build", "windows", "x64", "runner", "Release");
  const hostExe = join(DIR, "native-host", "target", "release", NMH);

  step("2/8 uygulama derleniyor (flutter build windows --release)");
  run("flutter", ["build", "windows", "--release"], join(DIR, "flutter_app"));

  step("3/8 kaynak surumu denetleniyor");
  verifyResourceVersion(version);

  step("4/8 tarayici koprusu derleniyor (cargo build --release --bin serene-nmh)");
  run("cargo", ["build", "--release", "--bin", "serene-nmh"], join(DIR, "native-host"));

  step("5/8 yayin klasoru hazirlaniyor");
  if (!existsSync(join(bundle, APP))) fail(`${APP} yok; onceki adimda derlenmemis`);
  const stage = stageRelease(version, bundle, hostExe);
  const staged = filesUnder(stage);
  const stageBytes = staged.reduce((sum, file) => sum + statSync(file).size, 0);
  console.log(`yayin klasoru: ${stage}`);
  console.log(`dosya: ${staged.length}, toplam: ${(stageBytes / 1024 / 1024).toFixed(1)} MB`);

  mkdirSync(DIST, { recursive: true });

  step("6/8 kurulum paketi derleniyor (makensis)");
  const installer = buildInstaller(version, stage, stageBytes);

  step("7/8 tasinabilir zip ve eklenti paketi");
  const zip = join(DIST, `Serene-${version}-portable.zip`);
  rmSync(zip, { force: true });
  writeZip(zip, staged, stage);
  console.log(`> ${zip}`);
  const extension = packExtension();

  step("8/8 surum notu");
  const notes = writeReleaseNotes(version);
  console.log(`> ${notes}`);

  console.log("\n--- OZET ---");
  console.log(`surum       : ${version}`);
  console.log(`kurulum     : ${installer}  (${mb(installer)})`);
  console.log(`tasinabilir : ${zip}  (${mb(zip)})`);
  for (const file of extension.copied) {
    console.log(`eklenti     : ${file}  (${mb(file)})`);
  }
  console.log(`surum notu  : ${notes}`);
  console.log(`yayin klas. : ${stage}`);
  console.log(`BASARILI: Serene ${version} yayini hazir`);
}

main();
