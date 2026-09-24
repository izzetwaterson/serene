/// Onay bekleyen tarayici devralmalarinin sirasi.
///
/// Harici onay penceresi yalnizca bir gorevi gosterir; sira ana pencerede
/// tutulur, boylece karar verildiginde ya da pencere kapandiginda siradaki
/// kendiliginden one gelir. Ayni gorev icin iki pencere acilmaz.
class HandoffQueue {
  final List<String> _waiting = [];
  String? _shown;

  /// Su an penceresi acik olan gorev.
  String? get shown => _shown;

  /// Sira disindaki gorevleri, yani artik onay beklemeyenleri dusurur.
  /// Penceresi acik gorev de listeden dustuyse kimligi doner: cagiran
  /// taraf o pencereyi kapatmali.
  String? sync(Iterable<String> pendingIds) {
    final live = pendingIds.toSet();
    _waiting.removeWhere((id) => !live.contains(id));
    final orphan = _shown;
    if (orphan != null && !live.contains(orphan)) {
      _shown = null;
      return orphan;
    }
    return null;
  }

  /// Gorevi siraya ekler; yeni devralma ve listedeki "Bilgileri Ac" ayni yoldan gecer.
  void request(String id) {
    if (_shown != id && !_waiting.contains(id)) _waiting.add(id);
  }

  /// Acik pencere yoksa siradaki gorevi ayirir ve "penceresi acik" isaretler.
  String? take() {
    if (_shown != null || _waiting.isEmpty) return null;
    return _shown = _waiting.removeAt(0);
  }

  /// Pencere kapandi. Gorev onay beklemeye devam etse bile siraya geri
  /// konmaz; kullanici listedeki dugmeyle yeniden açabilir.
  void close(String id) {
    if (_shown == id) _shown = null;
  }
}

/// FFI hatalari Dart'ta istisna olarak karsiliga cikar; kullaniciya Rust
/// tarafindaki Turkce kisa aciklama gosterilir.
String engineReason(Object error) =>
    error.toString().replaceFirst('Exception: ', '').trim();
