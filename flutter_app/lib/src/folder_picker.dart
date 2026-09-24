import 'package:file_picker/file_picker.dart';

/// Yerel klasor secme penceresinin tek kapisi; Tauri'daki `pick_directory`
/// komutunun karsiligi. Kullanici vazgecerse `null` doner.
Future<String?> pickFolder({
  required String title,
  String? initialDirectory,
}) async {
  final path = await FilePicker.getDirectoryPath(
    dialogTitle: title,
    initialDirectory: initialDirectory,
  );
  if (path == null || path.isEmpty) return null;
  return path;
}
