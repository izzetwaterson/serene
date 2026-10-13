import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Surum yoklamasinin okudugu adres.
///
/// Depo **gizli** oldugu surece GitHub API kimliksiz istekte `404` doner; depo
/// ve kurulumlar herkese acildiginda bu adres calisir. Baska bir yerde herkese
/// acik bir `latest.json` yayinlanirsa **yalniz bu satir** degisir: govde
/// cozumleyicisi hem GitHub surum JSON'unu (`tag_name`, `html_url`) hem de sade
/// `{"version": "...", "url": "..."}` bicimini kabul eder.
const updateCheckUrl =
    'https://api.github.com/repos/izzetwaterson/serene/releases/latest';

/// Yoklama adresini ezmek icin ortam degiskeni. Gelistirme ve dogrulama
/// kosumlari yerel bir sunucuya yonlendirmek icin kullanir (`SERENE_DATA_DIR`
/// gibi). Bos/verilmemis ise `updateCheckUrl` gecerlidir.
const updateUrlEnv = 'SERENE_UPDATE_URL';

/// Bulunan yeni surum; Ayarlar > Hakkinda buna abone olur. `null` ise ya
/// guncelleme yok ya da kontrol henuz bitmedi/erisilemedi.
final ValueNotifier<UpdateInfo?> availableUpdate = ValueNotifier<UpdateInfo?>(null);

/// Kullaniciya gosterilecek yeni surum bilgisi.
class UpdateInfo {
  const UpdateInfo({required this.version, required this.url});

  final String version;
  final String url;
}

/// Arka planda surumu yoklar. **Yalnizca okur**: surum adresine tek bir GET
/// gider, hicbir sey gonderilmez, indirme/kurulum yapilmaz. Yeni surum varsa
/// `availableUpdate` dolar; indirmeyi kullanici kendi yapar.
///
/// Hata, cevrimdisi, `404` (gizli depo) ya da bozuk govde **sessizce** yok
/// sayilir: sakin urun kurali geregi kullanici hicbir seyle rahatsiz edilmez.
/// `url` ve `SERENE_UPDATE_URL` yalnizca test/alternatif kaynak icindir;
/// varsayilan `updateCheckUrl`.
Future<void> checkForUpdate({
  required String currentVersion,
  String? url,
}) async {
  if (availableUpdate.value != null) return;
  final endpoint = url ?? _endpointFromEnv() ?? updateCheckUrl;
  try {
    final body = await _get(endpoint);
    final info = parseUpdate(body);
    if (info == null) return;
    if (isNewerVersion(info.version, currentVersion)) {
      availableUpdate.value = info;
    }
  } catch (_) {
    // Sessiz gec: ag yok, adres gizli, surum bozuk.
  }
}

String? _endpointFromEnv() {
  final value = Platform.environment[updateUrlEnv]?.trim();
  return (value == null || value.isEmpty) ? null : value;
}

Future<String> _get(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    request.headers.set(HttpHeaders.userAgentHeader, 'Serene');
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

/// Surum yanitini cozer. GitHub surum JSON'u (`tag_name`, `html_url`) ya da
/// sade `{"version", "url"}` bicimi kabul edilir; cozulemezse `null`.
UpdateInfo? parseUpdate(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final version = (decoded['version'] ?? decoded['tag_name'])?.toString();
  final url = (decoded['url'] ?? decoded['html_url'])?.toString();
  if (version == null || version.isEmpty) return null;
  if (url == null || !url.startsWith('http')) return null;
  return UpdateInfo(version: version, url: url);
}

/// `latest`, `current`ten yeni mi? Basindaki `v` ve `+`/`-` ekleri yok sayilir;
/// ilk uc sayisal parca karsilastirilir. Cozulemeyen surumde `false` doner
/// (yanlis guncelleme uyarisi gostermemek icin muhafazakar).
bool isNewerVersion(String latest, String current) {
  final a = _parts(latest);
  final b = _parts(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

List<int>? _parts(String raw) {
  final text = raw.trim().replaceFirst(RegExp(r'^[vV]'), '');
  final head = text.split(RegExp(r'[-+]')).first;
  final segments = head.split('.');
  if (segments.isEmpty || segments.first.isEmpty) return null;
  final out = <int>[0, 0, 0];
  for (var i = 0; i < segments.length && i < 3; i++) {
    final value = int.tryParse(segments[i]);
    if (value == null) return null;
    out[i] = value;
  }
  return out;
}
