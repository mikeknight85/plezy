import 'package:drift/drift.dart';

import '../models/transcode_quality_preset.dart';
import 'app_database.dart';

/// Persistence for [DownloadConversions]. A download without a row here
/// downloads the original file.
extension DownloadConversionOperations on AppDatabase {
  Future<DownloadConversionRow?> getDownloadConversion(String globalKey) =>
      (select(downloadConversions)..where((t) => t.globalKey.equals(globalKey))).getSingleOrNull();

  Future<List<DownloadConversionRow>> getDownloadConversions() => select(downloadConversions).get();

  /// Requests [quality] for [globalKey], replacing any earlier conversion.
  /// The caller discards the earlier server-side job first.
  Future<void> requestDownloadConversion(
    String globalKey, {
    required TranscodeQualityPreset quality,
    required String? clientScopeId,
  }) {
    assert(!quality.isOriginal);
    return into(downloadConversions).insertOnConflictUpdate(
      DownloadConversionsCompanion.insert(
        globalKey: globalKey,
        quality: quality.name,
        state: const Value(null),
        clientScopeId: Value(clientScopeId),
      ),
    );
  }

  /// Records [state] only while the row still holds the conversion that
  /// produced it: a newer request for the same download wins.
  Future<bool> updateDownloadConversionState(String globalKey, String? state, {required String quality}) async {
    final updated =
        await (update(downloadConversions)..where((t) => t.globalKey.equals(globalKey) & t.quality.equals(quality)))
            .write(DownloadConversionsCompanion(state: Value(state)));
    return updated > 0;
  }

  Future<void> deleteDownloadConversion(String globalKey) =>
      (delete(downloadConversions)..where((t) => t.globalKey.equals(globalKey))).go();
}
