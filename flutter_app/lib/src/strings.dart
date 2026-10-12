import 'package:flutter/foundation.dart';

/// Arayuz dili. Ayarlar katmani yazar, pencere kokleri dinler.
enum AppLanguage { tr, en }

final ValueNotifier<AppLanguage> appLanguage = ValueNotifier(AppLanguage.tr);

/// Ayar dizesinden dili cozer. Varsayilan Ingilizcedir; taninmayan deger de
/// Ingilizceye duser. Motordaki `normalize_language` ile ayni kumei tanir.
AppLanguage languageFrom(String raw) =>
    raw.trim().toLowerCase() == 'tr' ? AppLanguage.tr : AppLanguage.en;

String languageSetting(AppLanguage language) =>
    language == AppLanguage.en ? 'en' : 'tr';

/// Dilin kendi adi: secici hangi dilde bakilirsa bakilsin ayni yazilir.
String languageTitle(AppLanguage language) =>
    language == AppLanguage.en ? 'English' : 'Türkçe';

/// Dili uygular: once metinler hazir olur, sonra kokler yeniden kurulur.
void applyLanguage(AppLanguage language) {
  T = language == AppLanguage.en ? const EnStrings() : const TrStrings();
  appLanguage.value = language;
}

/// Motorun ayar dizesini uygular (`tr`, `en`).
void applyLanguageSetting(String raw) => applyLanguage(languageFrom(raw));

/// Arayuzun butun metinleri. Ikisi de ayni alanlari doldurur; eksik kalan
/// olursa derleyici soyler.
///
/// Etiket haritalari gibi bilesik parcalar da burada durur: cagri yerleri
/// `T.xxx` okur, boylece dil degisince metin de cagri aninda degisir.
abstract class Strings {
  const Strings();

  // --- Genel ---
  String get appTitle;
  String get handoffTitle;
  String get downloadTitle;
  String connectionsCount(int count);
  String get downloadGone;
  String get loading;
  String get settingsTitle;
  String get close;
  String get cancel;
  String get save;
  String get browse;
  String get other;
  String get downloadWord;
  String get saveWord;
  String get savedWord;
  String get unknownSize;
  String get unknownError;
  String get unknownDownload;
  String unknownAction(String action);
  String get thousandSeparator;
  String get bytesWord;

  // --- Gorev karti ve listesi ---
  String get activeDownloads;
  String taskCount(int count);
  String get nothingDownloading;
  String get nothingDownloadingHint;
  String get recentCompleted;
  String get seeAll;
  String get categoryFallback;
  String get downloads;
  String get nothingHere;
  String get nothingHereHint;
  String get heroTitle;
  String get urlPlaceholder;
  String get searchPlaceholder;
  String get chooseDifferentFolder;
  String get willBeSavedTo;
  String willBeSavedToPath(String path);
  String get removeCustomFolder;
  String get ignore;
  String get fromBrowser;
  String mediaCount(int count);
  String get clearAll;
  String get noCapturedMedia;
  String get noCapturedMediaHint;
  String get fileKind;
  String get mediaKind;

  // --- Durumlar ve eylemler ---
  String get statusPendingConfirm;
  String get statusDownloading;
  String get statusPaused;
  String get statusError;
  String get statusCompleted;
  String get statusQueued;
  String get queuedWaiting;
  String timeLeft(String eta);
  String get actionPause;
  String get actionCancel;
  String get actionDetails;
  String get actionResume;
  String get actionDequeue;
  String get actionRetry;
  String get actionRemove;
  String get actionOpen;
  String get actionReveal;
  Map<String, String> get filterTitles;
  Map<String, String> get categoryTitles;

  // --- Zaman ve sayilar ---
  String get unitSeconds;
  String get unitMinutes;
  String get unitHours;
  String get today;
  String get yesterday;
  List<String> get shortMonths;
  String dateLine(int day, String month, int? year, String clock);
  String get demoTimeoutError;

  // --- Ana pencere ---
  String get showWindow;
  String get pauseAllTray;
  String get quit;
  String get chooseFolderForDownload;
  String get pasteLinkIntoField;
  String capturedCleared(int count);
  String get browserConnected;
  String get browserMissing;
  String get localProfile;

  // --- Eklenti tanitimi ---
  String get extensionOfferTitle;
  String get extensionOfferBadge;
  String get extensionOfferBody;
  String get extensionOfferStep1;
  String get extensionOfferStep2;
  String get extensionOfferNote;
  String get extensionOfferOpen;
  String get extensionOfferInstall;
  String get extensionOfferLater;
  String get extensionOfferConnected;
  String get extensionPillHint;
  String get minimize;
  String get restore;
  String get maximize;
  String get queues;
  String get categories;
  String get disk;
  String driveOf(String mount);
  /// Yuzde isareti dilden dile yer degistirir (tr: "%94", en: "94%").
  String percentLabel(int percent);
  String get calculating;
  String diskUsed(String used, String total);
  String get demoWithSampleData;

  // --- Ayarlar ---
  String get folderLabel;
  String get chooseFolderTitle;
  String recordsDeleted(int count);
  String get nothingToDelete;
  String get concurrentLabel;
  String get concurrentHint;
  String get connectionsLabel;
  String get connectionsHint;
  String get appearanceLabel;
  String get themeSystem;
  String get themeLight;
  String get themeDark;
  String get languageLabel;
  String get watchClipboardTitle;
  String get watchClipboardHint;
  String get closeToTrayTitle;
  String get closeToTrayHint;
  String get confirmBrowserTitle;
  String get confirmBrowserHint;
  String get autostartTitle;
  String get autostartHint;
  String get clipboardToastTitle;
  String get clipboardDismiss;
  String get clipboardDownload;
  String get storageErrorTitle;
  String get storageErrorDismiss;
  String get tabGeneral;
  String get tabDownloads;
  String get tabBehaviour;
  String get tabAbout;
  String get aboutVersion;
  String get aboutEngine;
  String get aboutLicense;
  String get aboutRepository;
  String get aboutWebsite;
  String get aboutClose;
  String get aboutDescription;
  String get versionLabel;
  String get versionCopied;
  String get versionEngine;
  String get clearCompletedLabel;

  // --- Onay penceresi ---
  String get closeAndDownloadLater;
  String get serverSizeUnknown;
  String get serverSegmented;
  String get serverSingle;
  String get nameEmpty;
  String get dirEmpty;
  String get sampleTaskNoEngine;
  String sizeWithBytes(String size, String bytes);
  String get addressLabel;
  String get fileNameLabel;
  String get startDownload;
  String get downloadLater;
}

class TrStrings extends Strings {
  const TrStrings();

  @override
  String get appTitle => 'Serene';
  @override
  String get handoffTitle => 'İndirme Bilgileri';
  @override
  String get downloadTitle => 'İndiriliyor';
  @override
  String connectionsCount(int count) => '$count bağlantı';
  @override
  String get downloadGone => 'Bu indirme artık listede değil.';
  @override
  String get loading => 'Yükleniyor…';
  @override
  String get settingsTitle => 'Ayarlar';
  @override
  String get close => 'Kapat';
  @override
  String get cancel => 'İptal';
  @override
  String get save => 'Kaydet';
  @override
  String get browse => 'Gözat';
  @override
  String get other => 'Diğer';
  @override
  String get downloadWord => 'İndir';
  @override
  String get saveWord => 'Kaydet';
  @override
  String get savedWord => 'Kaydedildi';
  @override
  String get unknownSize => 'Boyut bilinmiyor';
  @override
  String get unknownError => 'Bilinmeyen hata';
  @override
  String get unknownDownload => 'Bilinmeyen indirme';
  @override
  String unknownAction(String action) => '"$action" islemi taninmiyor';
  @override
  String get thousandSeparator => '.';
  @override
  String get bytesWord => 'bayt';

  @override
  String get activeDownloads => 'Aktif İndirmeler';
  @override
  String taskCount(int count) => '$count görev';
  @override
  String get nothingDownloading => 'Şu an inen bir şey yok';
  @override
  String get nothingDownloadingHint =>
      'Yukarıdaki alana bir bağlantı yapıştırın; gerisini Serene halledecek.';
  @override
  String get recentCompleted => 'Son Tamamlananlar';
  @override
  String get seeAll => 'Tümünü Gör';
  @override
  String get categoryFallback => 'Kategori';
  @override
  String get downloads => 'İndirmeler';
  @override
  String get nothingHere => 'Burada bir şey yok';
  @override
  String get nothingHereHint => 'Bu görünümde eşleşen bir indirme bulunamadı.';
  @override
  String get heroTitle => 'Bugün ne indirmek istersiniz?';
  @override
  String get urlPlaceholder => 'https:// bağlantısını buraya bırakın...';
  @override
  String get searchPlaceholder => "İndirilenleri ara (örn: 'Nature')...";
  @override
  String get chooseDifferentFolder => 'Bu indirme için farklı klasör seç';
  @override
  String get willBeSavedTo => 'Bu indirme şuraya kaydedilecek:';
  @override
  String willBeSavedToPath(String path) => 'Bu indirme şuraya kaydedilecek: $path';
  @override
  String get removeCustomFolder => 'Özel klasörü kaldır';
  @override
  String get ignore => 'Yoksay';
  @override
  String get fromBrowser => 'Tarayıcıdan';
  @override
  String mediaCount(int count) => '$count medya';
  @override
  String get clearAll => 'Tümünü Temizle';
  @override
  String get noCapturedMedia => 'Yakalanan medya yok';
  @override
  String get noCapturedMediaHint =>
      'Tarayıcıda oynattığınız videolar ve sesler burada birikir; '
      'indirmek istediğinizi tek tıkla seçersiniz.';
  @override
  String get fileKind => 'Dosya';
  @override
  String get mediaKind => 'Medya';

  @override
  String get statusPendingConfirm => 'Onay bekliyor';
  @override
  String get statusDownloading => 'Devam ediyor';
  @override
  String get statusPaused => 'Duraklatıldı';
  @override
  String get statusError => 'Hata';
  @override
  String get statusCompleted => 'Tamamlandı';
  @override
  String get statusQueued => 'Kuyrukta';
  @override
  String get queuedWaiting => 'Kuyrukta bekliyor';
  @override
  String timeLeft(String eta) => 'Kalan süre: $eta';
  @override
  String get actionPause => 'Duraklat';
  @override
  String get actionCancel => 'İptal Et';
  @override
  String get actionDetails => 'Bilgileri Aç';
  @override
  String get actionResume => 'Devam Et';
  @override
  String get actionDequeue => 'Kuyruktan Çıkar';
  @override
  String get actionRetry => 'Yeniden Dene';
  @override
  String get actionRemove => 'Kaldır';
  @override
  String get actionOpen => 'Dosyayı Aç';
  @override
  String get actionReveal => 'Klasörde Göster';
  @override
  Map<String, String> get filterTitles => const {
        'all': 'Tüm İndirmeler',
        'active': 'Devam Edenler',
        'completed': 'Tamamlananlar',
        'queued': 'Kuyrukta',
        'failed': 'Hata Verenler',
      };
  @override
  Map<String, String> get categoryTitles => const {
        'video': 'Videolar',
        'audio': 'Sesler',
        'image': 'Görseller',
        'document': 'Belgeler',
        'software': 'Yazılımlar',
        'archive': 'Sıkıştırılmış',
        'other': 'Diğer',
      };

  @override
  String get unitSeconds => 'sn';
  @override
  String get unitMinutes => 'dk';
  @override
  String get unitHours => 'sa';
  @override
  String get today => 'Bugün';
  @override
  String get yesterday => 'Dün';
  @override
  List<String> get shortMonths => const [
        'Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz',
        'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara',
      ];
  @override
  String dateLine(int day, String month, int? year, String clock) =>
      year == null ? '$day $month, $clock' : '$day $month $year, $clock';
  @override
  String get demoTimeoutError => 'Bağlantı zaman aşımına uğradı';

  @override
  String get showWindow => 'Pencereyi Göster';
  @override
  String get pauseAllTray => 'Tümünü Duraklat';
  @override
  String get quit => 'Çıkış';
  @override
  String get chooseFolderForDownload => 'Bu indirme için klasör seçin';
  @override
  String get pasteLinkIntoField => 'Bağlantı alanına bir adres yapıştırın';
  @override
  String capturedCleared(int count) => '$count yakalama temizlendi';
  @override
  String get browserConnected => 'Tarayıcı bağlı';
  @override
  String get browserMissing => 'Tarayıcı yok';
  @override
  String get localProfile => 'Yerel profil';

  // --- Eklenti tanitimi ---
  @override
  String get extensionOfferTitle => 'Tarayıcı eklentisi';
  @override
  String get extensionOfferBadge => 'Önerilir';
  @override
  String get extensionOfferBody =>
      'İndirmeleri tarayıcıdan devralmak için Serene eklentisini Firefox\'a kur:';
  @override
  String get extensionOfferStep1 =>
      '«Firefox\'tan kur» düğmesine bas; Add-ons sayfası açılır.';
  @override
  String get extensionOfferStep2 =>
      'Sayfada «Add to Firefox» ile onayla; eklenti kurulur.';
  @override
  String get extensionOfferNote =>
      'Kurulum kalıcıdır. Elle yüklemek istersen «Eklenti klasörünü aç» ile '
      'about:debugging üzerinden geçici olarak da yükleyebilirsin.';
  @override
  String get extensionOfferOpen => 'Eklenti klasörünü aç';
  @override
  String get extensionOfferInstall => 'Firefox\'tan kur';
  @override
  String get extensionOfferLater => 'Şimdi değil';
  @override
  String get extensionOfferConnected => 'Eklenti bağlandı';
  @override
  String get extensionPillHint => 'Eklenti kurulumunu göster';
  @override
  String get minimize => 'Küçült';
  @override
  String get restore => 'Geri Al';
  @override
  String get maximize => 'Büyüt';
  @override
  String get queues => 'Kuyruklar';
  @override
  String get categories => 'Kategoriler';
  @override
  String get disk => 'Disk';
  @override
  String driveOf(String mount) => '$mount sürücüsü';
  @override
  String percentLabel(int percent) => '%$percent';
  @override
  String get calculating => 'Hesaplanıyor…';
  @override
  String diskUsed(String used, String total) =>
      '$used kullanılıyor / $total toplam alan';
  @override
  String get demoWithSampleData => 'Örnek veriyle göster';

  @override
  String get folderLabel => 'Kayıt klasörü';
  @override
  String get chooseFolderTitle => 'Kayıt klasörünü seçin';
  @override
  String recordsDeleted(int count) => '$count kayıt silindi';
  @override
  String get nothingToDelete => 'Silinecek kayıt yok';
  @override
  String get concurrentLabel => 'Eşzamanlı indirme';
  @override
  String get concurrentHint => 'Aynı anda kaç dosya iner';
  @override
  String get connectionsLabel => 'Bağlantı / dosya';
  @override
  String get connectionsHint => 'Parçalı indirmede bağlantı sayısı';
  @override
  String get appearanceLabel => 'Görünüm';
  @override
  String get themeSystem => 'Sistem';
  @override
  String get themeLight => 'Aydınlık';
  @override
  String get themeDark => 'Karanlık';
  @override
  String get languageLabel => 'Dil';
  @override
  String get watchClipboardTitle => 'Panoyu izle';
  @override
  String get watchClipboardHint => 'Kopyaladığınız bağlantıları yakalayıp önerir';
  @override
  String get closeToTrayTitle => 'Kapatınca tepsiye gizle';
  @override
  String get closeToTrayHint =>
      'Kapat düğmesi uygulamayı bitirmez, indirmeler sürer';
  @override
  String get confirmBrowserTitle => 'Tarayıcı indirmelerini önce sor';
  @override
  String get confirmBrowserHint =>
      'Devralınan indirme, bilgileri onaylanana kadar başlamaz';
  @override
  String get autostartTitle => 'Windows açılışında başlat';
  @override
  String get autostartHint =>
      'Bilgisayar açıldığında Serene kendiliğinden çalışır';
  @override
  String get clipboardToastTitle => 'Panodan bağlantı yakalandı';
  @override
  String get clipboardDismiss => 'Yoksay';
  @override
  String get clipboardDownload => 'İndir';
  @override
  String get storageErrorTitle => 'Görev listesi kaydedilemiyor';
  @override
  String get storageErrorDismiss => 'Kapat';
  @override
  String get tabGeneral => 'Genel';
  @override
  String get tabDownloads => 'Indirmeler';
  @override
  String get tabBehaviour => 'Davranis';
  @override
  String get tabAbout => 'Hakkinda';
  @override
  String get aboutVersion => 'Surum';
  @override
  String get aboutEngine => 'Motor';
  @override
  String get aboutLicense => 'Lisans';
  @override
  String get aboutRepository => 'Kaynak kodu';
  @override
  String get aboutWebsite => 'Web sitesi';
  @override
  String get aboutClose => 'Kapat';
  @override
  String get aboutDescription =>
      'Sakin ve duzenli bir indirme yoneticisi.';
  @override
  String get versionLabel => 'Surum';
  @override
  String get versionCopied => 'Kopyalandi';
  @override
  String get versionEngine => 'Motor';
  @override
  String get clearCompletedLabel => 'Tamamlananları temizle';

  @override
  String get closeAndDownloadLater => 'Kapat (sonra indir)';
  @override
  String get serverSizeUnknown =>
      'Sunucu boyutu bildirmedi; boyut indirme başlarken netleşecek.';
  @override
  String get serverSegmented =>
      'Sunucu parçalı indirmeyi destekliyor; dosya birden çok bağlantıyla '
      'daha hızlı inebilir.';
  @override
  String get serverSingle =>
      'Sunucu parçalı indirmeyi desteklemiyor; dosya tek bağlantıyla inecek.';
  @override
  String get nameEmpty => 'Dosya adı boş bırakılamaz.';
  @override
  String get dirEmpty => 'Kayıt klasörü boş olamaz.';
  @override
  String get sampleTaskNoEngine => 'Örnek görev motorla konuşmaz.';
  @override
  String sizeWithBytes(String size, String bytes) => '$size ($bytes bayt)';
  @override
  String get addressLabel => 'Adres';
  @override
  String get fileNameLabel => 'Dosya adı';
  @override
  String get startDownload => 'İndirmeyi Başlat';
  @override
  String get downloadLater => 'Sonra İndir';
}

class EnStrings extends Strings {
  const EnStrings();

  @override
  String get appTitle => 'Serene';
  @override
  String get handoffTitle => 'Download Info';
  @override
  String get downloadTitle => 'Downloading';
  @override
  String connectionsCount(int count) => '$count connections';
  @override
  String get downloadGone => 'This download is no longer in the list.';
  @override
  String get loading => 'Loading…';
  @override
  String get settingsTitle => 'Settings';
  @override
  String get close => 'Close';
  @override
  String get cancel => 'Cancel';
  @override
  String get save => 'Save';
  @override
  String get browse => 'Browse';
  @override
  String get other => 'Other';
  @override
  String get downloadWord => 'Download';
  @override
  String get saveWord => 'Save';
  @override
  String get savedWord => 'Saved';
  @override
  String get unknownSize => 'Size unknown';
  @override
  String get unknownError => 'Unknown error';
  @override
  String get unknownDownload => 'Unknown download';
  @override
  String unknownAction(String action) => 'Unknown action "$action"';
  @override
  String get thousandSeparator => ',';
  @override
  String get bytesWord => 'bytes';

  @override
  String get activeDownloads => 'Active Downloads';
  @override
  String taskCount(int count) => count == 1 ? '1 item' : '$count items';
  @override
  String get nothingDownloading => 'Nothing is downloading right now';
  @override
  String get nothingDownloadingHint =>
      'Paste a link into the field above; Serene will handle the rest.';
  @override
  String get recentCompleted => 'Recently Completed';
  @override
  String get seeAll => 'See All';
  @override
  String get categoryFallback => 'Category';
  @override
  String get downloads => 'Downloads';
  @override
  String get nothingHere => 'Nothing here';
  @override
  String get nothingHereHint => 'No downloads match this view.';
  @override
  String get heroTitle => 'What would you like to download today?';
  @override
  String get urlPlaceholder => 'Drop an https:// link here...';
  @override
  String get searchPlaceholder => "Search downloads (e.g. 'Nature')...";
  @override
  String get chooseDifferentFolder => 'Choose a different folder for this download';
  @override
  String get willBeSavedTo => 'This download will be saved to:';
  @override
  String willBeSavedToPath(String path) => 'This download will be saved to: $path';
  @override
  String get removeCustomFolder => 'Remove custom folder';
  @override
  String get ignore => 'Ignore';
  @override
  String get fromBrowser => 'From Browser';
  @override
  String mediaCount(int count) => count == 1 ? '1 media item' : '$count media items';
  @override
  String get clearAll => 'Clear All';
  @override
  String get noCapturedMedia => 'No captured media';
  @override
  String get noCapturedMediaHint =>
      'Videos and audio you play in the browser gather here; '
      'pick the one you want with a single click.';
  @override
  String get fileKind => 'File';
  @override
  String get mediaKind => 'Media';

  @override
  String get statusPendingConfirm => 'Awaiting confirmation';
  @override
  String get statusDownloading => 'Downloading';
  @override
  String get statusPaused => 'Paused';
  @override
  String get statusError => 'Error';
  @override
  String get statusCompleted => 'Completed';
  @override
  String get statusQueued => 'Queued';
  @override
  String get queuedWaiting => 'Waiting in queue';
  @override
  String timeLeft(String eta) => 'Time left: $eta';
  @override
  String get actionPause => 'Pause';
  @override
  String get actionCancel => 'Cancel';
  @override
  String get actionDetails => 'Open Details';
  @override
  String get actionResume => 'Resume';
  @override
  String get actionDequeue => 'Remove from Queue';
  @override
  String get actionRetry => 'Retry';
  @override
  String get actionRemove => 'Remove';
  @override
  String get actionOpen => 'Open File';
  @override
  String get actionReveal => 'Show in Folder';
  @override
  Map<String, String> get filterTitles => const {
        'all': 'All Downloads',
        'active': 'In Progress',
        'completed': 'Completed',
        'queued': 'Queued',
        'failed': 'Failed',
      };
  @override
  Map<String, String> get categoryTitles => const {
        'video': 'Videos',
        'audio': 'Audio',
        'image': 'Images',
        'document': 'Documents',
        'software': 'Software',
        'archive': 'Archives',
        'other': 'Other',
      };

  @override
  String get unitSeconds => 's';
  @override
  String get unitMinutes => 'm';
  @override
  String get unitHours => 'h';
  @override
  String get today => 'Today';
  @override
  String get yesterday => 'Yesterday';
  @override
  List<String> get shortMonths => const [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
  @override
  String dateLine(int day, String month, int? year, String clock) =>
      year == null ? '$month $day, $clock' : '$month $day, $year, $clock';
  @override
  String get demoTimeoutError => 'The connection timed out';

  @override
  String get showWindow => 'Show Window';
  @override
  String get pauseAllTray => 'Pause All';
  @override
  String get quit => 'Quit';
  @override
  String get chooseFolderForDownload => 'Choose a folder for this download';
  @override
  String get pasteLinkIntoField => 'Paste an address into the link field';
  @override
  String capturedCleared(int count) => '$count captures cleared';
  @override
  String get browserConnected => 'Browser connected';
  @override
  String get browserMissing => 'Browser offline';
  @override
  String get localProfile => 'Local profile';

  // --- Eklenti tanitimi ---
  @override
  String get extensionOfferTitle => 'Browser extension';
  @override
  String get extensionOfferBadge => 'Recommended';
  @override
  String get extensionOfferBody =>
      'Install the Serene extension in Firefox to take over downloads from your browser:';
  @override
  String get extensionOfferStep1 =>
      'Press "Install from Firefox"; the Add-ons page opens.';
  @override
  String get extensionOfferStep2 =>
      'Click "Add to Firefox" on the page to install it.';
  @override
  String get extensionOfferNote =>
      'The install is permanent. To load it by hand instead, press '
      '"Open extension folder" and use about:debugging.';
  @override
  String get extensionOfferOpen => 'Open extension folder';
  @override
  String get extensionOfferInstall => 'Install from Firefox';
  @override
  String get extensionOfferLater => 'Not now';
  @override
  String get extensionOfferConnected => 'Extension connected';
  @override
  String get extensionPillHint => 'Show extension setup';
  @override
  String get minimize => 'Minimize';
  @override
  String get restore => 'Restore';
  @override
  String get maximize => 'Maximize';
  @override
  String get queues => 'Queues';
  @override
  String get categories => 'Categories';
  @override
  String get disk => 'Disk';
  @override
  String driveOf(String mount) => '$mount drive';
  @override
  String percentLabel(int percent) => '$percent%';
  @override
  String get calculating => 'Calculating…';
  @override
  String diskUsed(String used, String total) => '$used used / $total total';
  @override
  String get demoWithSampleData => 'Show with sample data';

  @override
  String get folderLabel => 'Download folder';
  @override
  String get chooseFolderTitle => 'Choose the download folder';
  @override
  String recordsDeleted(int count) => count == 1 ? '1 record deleted' : '$count records deleted';
  @override
  String get nothingToDelete => 'Nothing to delete';
  @override
  String get concurrentLabel => 'Concurrent downloads';
  @override
  String get concurrentHint => 'How many files download at once';
  @override
  String get connectionsLabel => 'Connections / file';
  @override
  String get connectionsHint => 'Number of connections for segmented downloads';
  @override
  String get appearanceLabel => 'Appearance';
  @override
  String get themeSystem => 'System';
  @override
  String get themeLight => 'Light';
  @override
  String get themeDark => 'Dark';
  @override
  String get languageLabel => 'Language';
  @override
  String get watchClipboardTitle => 'Watch the clipboard';
  @override
  String get watchClipboardHint => 'Catches the links you copy and offers them';
  @override
  String get closeToTrayTitle => 'Hide to tray on close';
  @override
  String get closeToTrayHint =>
      'The close button does not quit the app; downloads keep running';
  @override
  String get confirmBrowserTitle => 'Ask before taking over browser downloads';
  @override
  String get confirmBrowserHint =>
      'A taken-over download waits until its details are confirmed';
  @override
  String get autostartTitle => 'Start when Windows starts';
  @override
  String get autostartHint => 'Serene launches itself when you sign in';
  @override
  String get clipboardToastTitle => 'Link caught from the clipboard';
  @override
  String get clipboardDismiss => 'Ignore';
  @override
  String get clipboardDownload => 'Download';
  @override
  String get storageErrorTitle => 'The task list cannot be saved';
  @override
  String get storageErrorDismiss => 'Dismiss';
  @override
  String get tabGeneral => 'General';
  @override
  String get tabDownloads => 'Downloads';
  @override
  String get tabBehaviour => 'Behaviour';
  @override
  String get tabAbout => 'About';
  @override
  String get aboutVersion => 'Version';
  @override
  String get aboutEngine => 'Engine';
  @override
  String get aboutLicense => 'Licence';
  @override
  String get aboutRepository => 'Source code';
  @override
  String get aboutWebsite => 'Website';
  @override
  String get aboutClose => 'Close';
  @override
  String get aboutDescription =>
      'A calm, tidy download manager for Windows.';
  @override
  String get versionLabel => 'Version';
  @override
  String get versionCopied => 'Copied';
  @override
  String get versionEngine => 'Engine';
  @override
  String get clearCompletedLabel => 'Clear completed';

  @override
  String get closeAndDownloadLater => 'Close (download later)';
  @override
  String get serverSizeUnknown =>
      'The server did not report a size; it will be clear once the download '
      'starts.';
  @override
  String get serverSegmented =>
      'The server supports segmented downloads; the file can arrive faster '
      'over multiple connections.';
  @override
  String get serverSingle =>
      'The server does not support segmented downloads; the file will use a '
      'single connection.';
  @override
  String get nameEmpty => 'The file name cannot be empty.';
  @override
  String get dirEmpty => 'The download folder cannot be empty.';
  @override
  String get sampleTaskNoEngine => 'A sample task does not talk to the engine.';
  @override
  String sizeWithBytes(String size, String bytes) => '$size ($bytes bytes)';
  @override
  String get addressLabel => 'Address';
  @override
  String get fileNameLabel => 'File name';
  @override
  String get startDownload => 'Start Download';
  @override
  String get downloadLater => 'Download Later';
}

/// Aktif metinler. Palet gibi globaldir: dil degisince kokler agaci yeniden
/// kurar ve cagri yerleri yeni degerleri okur.
Strings T = const TrStrings();
