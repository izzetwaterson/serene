//! Video ve sesi tek dosyaya mux'lamak icin `ffmpeg`.
//!
//! Arama sirasi (ilk bulunan kazanir):
//!   1. `SERENE_FFMPEG` ortam degiskeni (aciş/kacis yolu)
//!   2. uygulamanin yanindaki `tools\ffmpeg\ffmpeg.exe` (kurulum paketiyle gelir, LGPL)
//!   3. exe'nin yanindaki `ffmpeg.exe` (elle konmus / tasinabilir)
//!   4. `PATH`
//!
//! Harici ve opsiyoneldir: hicbiri bulunamazsa ya da mux basarisiz olursa
//! cagiran yedek yola duser (video ana dosya, ses ayri).

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{anyhow, Result};

/// ffmpeg yolunu ezmek icin ortam degiskeni (test ve elle kosum icin).
pub const ENV_OVERRIDE: &str = "SERENE_FFMPEG";

/// Windows'ta calistirilabilir dosyanin adi; digerlerinde uzantisiz.
#[cfg(windows)]
const EXE_NAME: &str = "ffmpeg.exe";
#[cfg(not(windows))]
const EXE_NAME: &str = "ffmpeg";

/// Adaylar arasindan **var olan ilkini** secer.
///
/// Saf fonksiyon: dosya sistemi `exists` ile disaridan verilir, bu yuzden
/// gercek disk olmadan test edilebilir.
pub fn choose(candidates: &[Option<PathBuf>], exists: impl Fn(&Path) -> bool) -> Option<PathBuf> {
    candidates
        .iter()
        .flatten()
        .find(|candidate| exists(candidate))
        .cloned()
}

/// ffmpeg yolunu bulur: once `SERENE_FFMPEG`, sonra uygulamanin yanindaki
/// `tools\ffmpeg\ffmpeg.exe`, sonra exe yanindaki `ffmpeg.exe`, en son `PATH`.
pub fn locate() -> Option<PathBuf> {
    resolve()
}

fn resolve() -> Option<PathBuf> {
    let from_env = std::env::var_os(ENV_OVERRIDE).map(PathBuf::from);
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(Path::to_path_buf));
    // Paketle gelen yol bir alt klasorde: kullanicinin kurulum klasorunde
    // dagilmis tek bir `ffmpeg.exe` gormemesi icin (JDownloader deseni).
    let bundled = exe_dir
        .as_ref()
        .map(|dir| dir.join("tools").join("ffmpeg").join(EXE_NAME));
    let beside_exe = exe_dir.map(|dir| dir.join(EXE_NAME));
    let on_path = find_on_path();

    choose(&[from_env, bundled, beside_exe, on_path], |path| path.is_file())
}

/// `PATH` icindeki `ffmpeg`i arar (harici crate olmadan).
fn find_on_path() -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    let exe = OsString::from(EXE_NAME);
    std::env::split_paths(&path)
        .map(|dir| dir.join(&exe))
        .find(|candidate| candidate.is_file())
}

/// Kullanilabilir bir ffmpeg var mi?
pub fn available() -> bool {
    locate().is_some()
}

/// Video ve sesi yeniden kodlamadan tek dosyaya mux eder.
pub async fn mux(video: &Path, audio: &Path, dest: &Path) -> Result<()> {
    let video = video.to_path_buf();
    let audio = audio.to_path_buf();
    let dest = dest.to_path_buf();
    tokio::task::spawn_blocking(move || run_mux(&video, &audio, &dest))
        .await
        .map_err(|err| anyhow!("ffmpeg gorevi coktu: {err}"))?
}

fn run_mux(video: &Path, audio: &Path, dest: &Path) -> Result<()> {
    let program = locate().ok_or_else(|| anyhow!("ffmpeg bulunamadi"))?;
    let output = Command::new(program)
        .arg("-y")
        .arg("-loglevel")
        .arg("error")
        .arg("-i")
        .arg(video)
        .arg("-i")
        .arg(audio)
        .arg("-c")
        .arg("copy")
        .arg("-movflags")
        .arg("+faststart")
        .arg(dest)
        .stdin(Stdio::null())
        .output()
        .map_err(|err| anyhow!("ffmpeg calistirilamadi: {err}"))?;
    if !output.status.success() {
        let message = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow!("ffmpeg mux basarisiz: {}", message.trim()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn choose_prefers_the_first_existing_candidate() {
        let env_path = PathBuf::from("C:/kacis/ffmpeg.exe");
        let beside = PathBuf::from("C:/kurulum/ffmpeg.exe");
        let on_path = PathBuf::from("C:/araclar/ffmpeg.exe");

        // Yalniz `PATH` adayi varsa o secilir.
        let picked = choose(
            &[Some(env_path.clone()), Some(beside.clone()), Some(on_path.clone())],
            |path| path == on_path,
        );
        assert_eq!(picked, Some(on_path));

        // Uygulamanin yanindaki, `PATH`ten once gelir.
        let beside_now = beside.clone();
        let picked = choose(&[Some(env_path.clone()), Some(beside.clone())], |path| {
            path == beside_now || path == Path::new("C:/araclar/ffmpeg.exe")
        });
        assert_eq!(picked, Some(beside));
    }

    #[test]
    fn choose_returns_none_without_a_real_candidate() {
        let missing = PathBuf::from("C:/yok/ffmpeg.exe");
        assert_eq!(choose(&[Some(missing), None], |_| false), None);
        assert_eq!(choose(&[], |_| true), None);
    }

    #[test]
    fn bundled_subfolder_wins_over_path() {
        // Paketle gelen `tools\ffmpeg\ffmpeg.exe`, PATH'teki bir ffmpeg'ten once.
        let bundled = PathBuf::from("C:/Serene/tools/ffmpeg/ffmpeg.exe");
        let on_path = PathBuf::from("C:/araclar/ffmpeg.exe");
        let picked = choose(
            &[None, Some(bundled.clone()), None, Some(on_path.clone())],
            |path| path == bundled || path == on_path,
        );
        assert_eq!(picked, Some(bundled));
    }
}
