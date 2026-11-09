import '../models/transcode_quality_preset.dart';
import 'media_server_client.dart';

/// A client whose server can prepare a smaller copy of a video for download.
///
/// Backends without this interface, and servers or users that do not offer
/// it, download the original file exactly as they always have.
abstract interface class DownloadConversionSource {
  /// Whether to offer a download quality choice right now. Synchronous and
  /// request-free, so asking it never slows down the download flow.
  bool get offersDownloadConversion;

  /// The conversion service for this client's current user. Also used to
  /// continue conversions started earlier, even while
  /// [offersDownloadConversion] is not yet known after a restart.
  DownloadConversion get downloadConversion;
}

/// The conversion service of [client], or `null` when it has none.
DownloadConversion? downloadConversionOf(MediaServerClient client) => switch (client) {
  final DownloadConversionSource source => source.downloadConversion,
  _ => null,
};

/// Whether [client] currently offers a download quality choice.
bool offersDownloadConversion(MediaServerClient client) => switch (client) {
  final DownloadConversionSource source => source.offersDownloadConversion,
  _ => false,
};

/// What to convert: one source version of one video, at one quality.
class DownloadConversionRequest {
  final String itemId;

  /// Position of the source version when the download was queued.
  final int mediaIndex;

  /// Stable ID of the source version, preferred over [mediaIndex] because a
  /// server can reorder versions while a conversion waits.
  final String? mediaSourceId;

  final TranscodeQualityPreset quality;

  const DownloadConversionRequest({
    required this.itemId,
    required this.mediaIndex,
    required this.mediaSourceId,
    required this.quality,
  }) : assert(quality != TranscodeQualityPreset.original);
}

/// A server-side conversion, advanced one step at a time by the download
/// manager. Progress lives on the server, so a conversion keeps going while
/// the app is suspended and continues from its persisted state afterwards.
abstract interface class DownloadConversion {
  /// File extension of every prepared copy, such as `mkv`.
  String get outputExtension;

  /// Moves the conversion forward and reports where it stands.
  ///
  /// [state] is the opaque state of the previous step, or `null` to start.
  /// [persist] is called whenever the server creates something that must be
  /// cleaned up later, before the next request, so a crash cannot orphan it.
  Future<DownloadConversionStep> advance(
    DownloadConversionRequest request, {
    String? state,
    required Future<void> Function(String state) persist,
  });

  /// Releases the server-side job behind [state]. Best effort: never throws.
  Future<void> discard(String state);
}

/// Where a conversion stands after [DownloadConversion.advance].
sealed class DownloadConversionStep {
  const DownloadConversionStep();
}

/// The server is still preparing the copy. [progress] is 0–1 when known.
final class DownloadConversionPreparing extends DownloadConversionStep {
  final String state;
  final double? progress;

  const DownloadConversionPreparing({required this.state, this.progress});
}

/// The copy is ready to download from [url].
final class DownloadConversionReady extends DownloadConversionStep {
  final String state;
  final String url;

  const DownloadConversionReady({required this.state, required this.url});
}

/// The server could not prepare the copy. Its job is already discarded.
final class DownloadConversionFailed extends DownloadConversionStep {
  final String message;

  const DownloadConversionFailed(this.message);
}

/// A download failed because the server could not prepare its copy.
/// [message] is the server's English reason, kept for logs.
class DownloadConversionException implements Exception {
  final String message;

  const DownloadConversionException(this.message);

  @override
  String toString() => 'DownloadConversionException: $message';
}
