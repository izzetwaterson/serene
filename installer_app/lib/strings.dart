import 'dart:io';

/// Kurulum arayuzunun metinleri. Dil sistem yerelinden gelir (Turkce ise
/// Turkce, aksi halde Ingilizce); kullaniciya dil sorulmaz.
class L {
  const L._(this._tr);

  final bool _tr;

  /// Sistem dili Turkce mi.
  static bool get systemIsTurkish => Platform.localeName.toLowerCase().startsWith('tr');

  static L current = L._(systemIsTurkish);

  /// Dili degistirir (dil sayfasi ya da `--lang`).
  static void use(bool turkish) => current = L._(turkish);

  bool get isTurkish => _tr;

  String _t(String en, String tr) => _tr ? tr : en;

  // Dil sayfasi: iki dilde birden, secimden once gorunur.
  String get languageTitle => 'Choose your language';
  String get languageSubtitle => 'Dilini seç';
  String get continueLabel => _t('Continue', 'Devam');

  // Marka
  String get tagline => _t('A calm download manager.', 'Sakin bir indirme yöneticisi.');
  String get setupTitle => _t('Serene Setup', 'Serene Kurulum');

  // Karsilama
  String get welcomeTitle => _t('Welcome to Serene', 'Serene’e hoş geldin');
  String get welcomeBody => _t(
      'Setup takes a few seconds and does not need administrator rights.',
      'Kurulum birkaç saniye sürer ve yönetici yetkisi gerektirmez.');
  String get install => _t('Install', 'Kur');
  String get customize => _t('Customize', 'Özelleştir');
  String get back => _t('Back', 'Geri');
  String get version => _t('Version', 'Sürüm');

  // Calisan uygulama
  String get runningTitle => _t('Serene is running', 'Serene çalışıyor');
  String get runningBody => _t(
      'Its files are in use. Close it to continue; unfinished downloads resume next time.',
      'Dosyaları kullanımda. Devam etmek için kapat; yarım indirmeler bir sonraki açılışta sürer.');
  String get closeSerene => _t('Close Serene', 'Serene’i kapat');

  // Secenekler
  String get optionsTitle => _t('Setup options', 'Kurulum ayarları');
  String get installFolder => _t('Install folder', 'Kurulum klasörü');
  String get change => _t('Change…', 'Değiştir…');
  String get optStartMenu => _t('Start menu shortcut', 'Başlat menüsü kısayolu');
  String get optStartMenuHint => _t('Adds Serene to the Start menu.', 'Serene’i Başlat menüsüne ekler.');
  String get optDesktop => _t('Desktop shortcut', 'Masaüstü kısayolu');
  String get optDesktopHint => _t('Adds Serene to the desktop.', 'Serene’i masaüstüne ekler.');
  String get optAutostart => _t('Start with Windows', 'Windows ile başlat');
  String get optAutostartHint => _t('Starts when you sign in.', 'Oturum açıldığında başlar.');
  String get pickFolder => _t('Choose install folder', 'Kurulum klasörünü seç');

  // Ilerleme
  String get installingTitle => _t('Installing…', 'Kuruluyor…');
  String get stepFiles => _t('Copying files', 'Dosyalar kopyalanıyor');
  String get stepRegister => _t('Registering with Windows', 'Windows’a kaydediliyor');
  String get stepShortcut => _t('Adding shortcut', 'Kısayol ekleniyor');
  String get stepDesktop => _t('Adding desktop shortcut', 'Masaüstü kısayolu ekleniyor');
  String get stepAutostart => _t('Setting up autostart', 'Otomatik başlatma ayarlanıyor');
  String get stepDone => _t('Finishing up', 'Tamamlanıyor');

  // Bitis
  String get doneTitle => _t('Setup complete', 'Kurulum tamamlandı');
  String get doneBody => _t('Serene is ready to use.', 'Serene kullanıma hazır.');
  String get launchSerene => _t('Open Serene', 'Serene’i aç');
  String get finish => _t('Finish', 'Bitir');

  // Hata
  String get errorTitle => _t('Setup could not finish', 'Kurulum tamamlanamadı');
  String get close => _t('Close', 'Kapat');
  String get retry => _t('Try again', 'Tekrar dene');

  // Kaldirma
  String get uninstallTitle => _t('Uninstall Serene?', 'Serene kaldırılsın mı?');
  String get uninstallBody => _t(
      'Serene will be removed from this computer. Your downloaded files will not be deleted.',
      'Serene bu bilgisayardan kaldırılacak. İndirdiğin dosyalar silinmez.');
  String get keepData => _t('Keep my download list and settings', 'İndirme listemi ve ayarlarımı koru');
  String get keepDataHint => _t(
      'Your list and settings are kept if you reinstall.', 'Yeniden kurarsan listen ve ayarların korunur.');
  String get uninstall => _t('Uninstall', 'Kaldır');
  String get cancel => _t('Cancel', 'Vazgeç');
  String get removingTitle => _t('Uninstalling…', 'Kaldırılıyor…');
  String get stepRemoveBridge => _t('Disconnecting the browser bridge', 'Tarayıcı köprüsü ayrılıyor');
  String get stepRemoveFiles => _t('Removing files', 'Dosyalar kaldırılıyor');
  String get stepRemoveRegistry => _t('Cleaning up Windows entries', 'Windows kayıtları temizleniyor');
  String get stepRemoveData => _t('Deleting your data', 'Verilerin siliniyor');
  String get removedTitle => _t('Serene was removed', 'Serene kaldırıldı');
  String get removedBody => _t('Your downloaded files were not deleted.', 'İndirdiğin dosyalar silinmedi.');
  String get notInstalled => _t('Serene does not seem to be installed.', 'Serene kurulu görünmüyor.');

  // Deneme varyantlari icin kisa etiketler
  String get wizLang => _t('Language', 'Dil');
  String get wizSetup => _t('Setup', 'Kurulum');
  String get wizDone => _t('Done', 'Bitti');
  String get wizConfirm => _t('Confirm', 'Onay');
  String get wizRemove => _t('Removing', 'Kaldırma');
  String get whereTitle => _t('Where should Serene be installed?', 'Serene nereye kurulsun?');
  String get browse => _t('Browse…', 'Gözat…');
}
