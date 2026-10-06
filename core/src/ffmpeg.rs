//! Video ve sesi tek dosyaya mux'lamak icin `ffmpeg` (varsa).
//!
//! Harici ve opsiyoneldir: PATH'te bulunamazsa ya da mux basarisiz olursa
//! cagiran yedek yola duser (video ana dosya, ses ayri).

use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::OnceLock;

use anyhow::{anyhow, Result};

/// `ffmpeg` PATH'te var mi? Sonuc surec omru boyunca bir kez olculur.
pub fn available() -> bool {
    static READY: OnceLock<bool> = OnceLock::new();
    *READY.get_or_init(|| {
        Command::new("ffmpeg")
            .arg("-version")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    })
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
    let output = Command::new("ffmpeg")
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
