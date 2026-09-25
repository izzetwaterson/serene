//! Firefox native messaging host'u.
//!
//! Firefox bu ikiliyi stdio uzerinden konusturur: mesajlar 4 baytlik yerel
//! bayt sirasi uzunluk oneki + UTF-8 JSON govdesi seklindedir.
//!
//! Ikili bilerek indirme motorunu ve Tauri'yi linklemez (bkz. `native-host/`):
//! boylece kucuk kalir ve tarayici tarafindan hizlica baslatilir.
//! Gorevi iki yonlu saydam bir boru olmaktir:
//!
//!   Firefox  <--stdio-->  serene-nmh  <--127.0.0.1-->  serene.exe (kopru)
//!
//! Uygulama kapaliysa sessizce baslatir (pencere one gelmez, tepsiye yerlesir).

use serene_native_host as native_host;

use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Deserialize;

/// Firefox'un izin verdigi en buyuk mesaj; asilirsa protokol bozulmus demektir.
const MAX_FRAME: usize = 64 * 1024 * 1024;

#[derive(Debug, Deserialize)]
struct IpcInfo {
    port: u16,
    token: String,
}

/// Kopruye bagli iki yari. Okuma yarisi tamponlu oldugu icin ayri tutulur;
/// aksi halde el sikismasi sirasinda tamponlanan baytlar kaybolur.
struct Link {
    reader: BufReader<TcpStream>,
    writer: TcpStream,
}

fn read_frame(reader: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut len_buf = [0u8; 4];
    match reader.read_exact(&mut len_buf) {
        Ok(()) => {}
        Err(err) if err.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(err) => return Err(err),
    }

    let len = u32::from_ne_bytes(len_buf) as usize;
    if len == 0 || len > MAX_FRAME {
        return Ok(None);
    }

    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf)?;
    Ok(Some(buf))
}

fn write_frame(writer: &mut impl Write, payload: &[u8]) -> io::Result<()> {
    writer.write_all(&(payload.len() as u32).to_ne_bytes())?;
    writer.write_all(payload)?;
    writer.flush()
}

fn read_ipc() -> Option<IpcInfo> {
    let path = native_host::data_dir().join("ipc.json");
    let text = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

/// Uygulamayi pencere one cikarmadan baslatir.
///
/// Ikilinin adi kabuga gore degisir: Tauri kabugu `serene.exe`, Flutter kabugu
/// `serene_app.exe`. Hangisinin bu klasorde durdugu burada cozulur; iki kabuk
/// ayni anda yan yana bulunmadigi icin karisiklik cikmaz.
fn launch_app() {
    let Ok(nmh) = native_host::nmh_exe_path() else {
        return;
    };
    let Some(dir) = nmh.parent() else {
        return;
    };
    let Some(exe) = ["serene.exe", "serene_app.exe"]
        .iter()
        .map(|name| dir.join(name))
        .find(|path| path.exists())
    else {
        return;
    };

    let mut command = Command::new(&exe);
    command
        .current_dir(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }

    let _ = command.spawn();
}

fn try_connect(info: &IpcInfo) -> io::Result<Link> {
    let stream = TcpStream::connect(("127.0.0.1", info.port))?;
    let _ = stream.set_nodelay(true);

    let mut writer = stream.try_clone()?;
    let hello = serde_json::json!({ "type": "hello", "token": info.token }).to_string();
    writer.write_all(hello.as_bytes())?;
    writer.write_all(b"\n")?;
    writer.flush()?;

    let mut reader = BufReader::new(stream.try_clone()?);
    let mut line = String::new();
    reader.read_line(&mut line)?;

    let value: serde_json::Value = serde_json::from_str(line.trim())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "gecersiz el sikismasi"))?;

    if value.get("type").and_then(|v| v.as_str()) != Some("ready") {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "kopru token'i reddedildi",
        ));
    }

    Ok(Link { reader, writer })
}

/// Once mevcut kopruyu dener; yoksa uygulamayi baslatip `ipc.json`'u bekler.
fn connect_bridge() -> Result<Link, String> {
    if let Some(info) = read_ipc() {
        if let Ok(link) = try_connect(&info) {
            return Ok(link);
        }
    }

    launch_app();

    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(300));
        if let Some(info) = read_ipc() {
            if let Ok(link) = try_connect(&info) {
                return Ok(link);
            }
        }
    }

    Err("Serene koprusune baglanilamadi".to_string())
}

fn run_host() -> i32 {
    let link = match connect_bridge() {
        Ok(link) => link,
        Err(message) => {
            // Hata mesaji Firefox konsolunda gorunur; kullanici sebebi anlasin.
            eprintln!("serene-nmh: {message}");
            return 1;
        }
    };

    let stdout = Arc::new(Mutex::new(io::stdout()));
    let (tx, rx) = mpsc::channel::<Vec<u8>>();

    // stdin kapandiginda yazma yarisini da kapat ki karsi taraf haberdar olsun.
    let shutdown_handle = link.writer.try_clone().ok();
    let reader_handle = std::thread::spawn(move || {
        let mut stdin = io::stdin();
        while let Ok(Some(frame)) = read_frame(&mut stdin) {
            if tx.send(frame).is_err() {
                break;
            }
        }
        if let Some(stream) = shutdown_handle {
            let _ = stream.shutdown(Shutdown::Write);
        }
    });

    let mut writer = link.writer;
    let writer_handle = std::thread::spawn(move || {
        for frame in rx {
            let text = String::from_utf8_lossy(&frame).trim().to_string();
            if text.is_empty() {
                continue;
            }
            if writer.write_all(text.as_bytes()).is_err() {
                break;
            }
            if writer.write_all(b"\n").is_err() {
                break;
            }
            if writer.flush().is_err() {
                break;
            }
        }
        let _ = writer.shutdown(Shutdown::Write);
    });

    let mut reader = link.reader;
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {
                let text = line.trim();
                if text.is_empty() {
                    continue;
                }
                let Ok(mut out) = stdout.lock() else {
                    break;
                };
                if write_frame(&mut *out, text.as_bytes()).is_err() {
                    break;
                }
            }
            Err(_) => break,
        }
    }

    let _ = writer_handle.join();
    let _ = reader_handle.join();
    0
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    if args.iter().any(|arg| arg == "--register-host") {
        let code = match native_host::register() {
            Ok(path) => {
                println!("Native messaging host kaydedildi: {}", path.display());
                0
            }
            Err(message) => {
                eprintln!("{message}");
                1
            }
        };
        std::process::exit(code);
    }

    if args.iter().any(|arg| arg == "--unregister-host") {
        let code = match native_host::unregister() {
            Ok(()) => {
                println!("Native messaging host kaydi silindi");
                0
            }
            Err(message) => {
                eprintln!("{message}");
                1
            }
        };
        std::process::exit(code);
    }

    std::process::exit(run_host());
}
