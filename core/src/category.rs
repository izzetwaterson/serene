use crate::models::Category;

/// Uzantiya gore kategori belirler. Sadece arayuz filtresi icin kullanilir,
/// dosyalar kategori klasorlerine tasinmaz.
pub fn classify(filename: &str) -> Category {
    let ext = filename
        .rsplit_once('.')
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default();

    match ext.as_str() {
        "mp4" | "mkv" | "avi" | "mov" | "webm" | "flv" | "wmv" | "m4v" | "mpg" | "mpeg" | "ts"
        | "3gp" | "m2ts" => Category::Video,

        "mp3" | "wav" | "flac" | "aac" | "ogg" | "m4a" | "opus" | "wma" | "aiff" => Category::Audio,

        "jpg" | "jpeg" | "png" | "gif" | "webp" | "bmp" | "svg" | "tiff" | "ico" | "avif"
        | "heic" => Category::Image,

        "pdf" | "doc" | "docx" | "xls" | "xlsx" | "ppt" | "pptx" | "txt" | "md" | "rtf"
        | "odt" | "ods" | "odp" | "csv" | "epub" | "mobi" | "json" | "xml" => Category::Document,

        "exe" | "msi" | "msix" | "appx" | "dmg" | "pkg" | "deb" | "rpm" | "apk" | "bat"
        | "cmd" | "ps1" | "jar" => Category::Software,

        "zip" | "rar" | "7z" | "tar" | "gz" | "bz2" | "xz" | "zst" | "iso" | "tgz"
        | "cab" => Category::Archive,

        _ => Category::Other,
    }
}
