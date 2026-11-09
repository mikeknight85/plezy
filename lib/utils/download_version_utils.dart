import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../media/download_conversion.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../media/media_version.dart';
import '../media/episode_collection.dart';
import '../models/transcode_quality_preset.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/media_version_resolver.dart';
import '../utils/quality_preset_labels.dart';
import '../i18n/strings.g.dart';

/// Configuration for download version selection, threaded through the queue pipeline.
class DownloadVersionConfig {
  final int mediaIndex;

  /// The copy to download. Anything but original asks the server to
  /// prepare a smaller file; only offered where the server supports it.
  final TranscodeQualityPreset quality;
  final Set<String> acceptedSignatures;
  final Future<int?> Function(MediaItem episode, List<MediaVersion> versions)? onVersionMismatch;

  DownloadVersionConfig({
    this.mediaIndex = 0,
    this.quality = TranscodeQualityPreset.original,
    Set<String>? acceptedSignatures,
    this.onVersionMismatch,
  }) : acceptedSignatures = acceptedSignatures ?? {};

  DownloadVersionConfig withQuality(TranscodeQualityPreset quality) => DownloadVersionConfig(
    mediaIndex: mediaIndex,
    quality: quality,
    acceptedSignatures: acceptedSignatures,
    onVersionMismatch: onVersionMismatch,
  );

  /// Create from a selected version's signature.
  factory DownloadVersionConfig.fromSignature(
    String signature, {
    int mediaIndex = 0,
    Future<int?> Function(MediaItem, List<MediaVersion>)? onVersionMismatch,
  }) {
    return DownloadVersionConfig(
      mediaIndex: mediaIndex,
      acceptedSignatures: {signature},
      onVersionMismatch: onVersionMismatch,
    );
  }
}

/// Resolve version selection for a download. Shows picker if needed.
/// Returns null if the user cancels, or a config with the selection.
///
/// Where the server can prepare a smaller copy ([offersDownloadConversion]),
/// video downloads also ask for a quality. Everywhere else the flow, and the
/// result, are exactly what they were before quality existed.
Future<DownloadVersionConfig?> resolveDownloadVersion(
  BuildContext context,
  MediaItem metadata,
  MediaServerClient client, {
  List<MediaVersion>? fallbackVersions,
}) async {
  final kind = metadata.kind;
  final offersQuality =
      offersDownloadConversion(client) &&
      const {MediaKind.movie, MediaKind.episode, MediaKind.show, MediaKind.season}.contains(kind);

  if (kind == MediaKind.movie || kind == MediaKind.episode) {
    final versions = await resolveMediaVersions(metadata, client, fallbackVersions: fallbackVersions);
    if (!context.mounted) return null;
    var config = DownloadVersionConfig();
    if (versions.length > 1) {
      final selectedIndex = await showVersionPickerDialog(context, versions, t.downloads.selectVersion);
      if (selectedIndex == null || !context.mounted) return null;
      config = DownloadVersionConfig(mediaIndex: selectedIndex);
    }
    if (!offersQuality) return config;
    final version = config.mediaIndex < versions.length ? versions[config.mediaIndex] : null;
    final quality = await _pickDownloadQuality(context, version: version, durationMs: metadata.durationMs);
    return quality == null ? null : config.withQuality(quality);
  }

  if (kind == MediaKind.show || kind == MediaKind.season) {
    final versions = await fetchRepresentativeVersions(client, metadata);
    var config = DownloadVersionConfig();
    if (versions != null && versions.length > 1) {
      if (!context.mounted) return null;
      final selectedIndex = await showVersionPickerDialog(context, versions, t.downloads.selectVersion);
      if (selectedIndex == null || !context.mounted) return null;
      config = DownloadVersionConfig.fromSignature(
        versions[selectedIndex].signature,
        mediaIndex: selectedIndex,
        onVersionMismatch: (episode, episodeVersions) async {
          if (!context.mounted) return null;
          return showVersionPickerDialog(
            context,
            episodeVersions,
            '${episode.displayTitle} - ${t.downloads.selectVersion}',
          );
        },
      );
    }
    if (!offersQuality) return config;
    if (!context.mounted) return null;
    // Episodes differ in length, so no size estimate for a whole show.
    final quality = await _pickDownloadQuality(context);
    return quality == null ? null : config.withQuality(quality);
  }

  return DownloadVersionConfig();
}

Future<TranscodeQualityPreset?> _pickDownloadQuality(BuildContext context, {MediaVersion? version, int? durationMs}) {
  return showQualityPickerDialog(
    context,
    title: t.downloads.selectQuality,
    description: t.downloads.preparationBackgroundHint,
    sourceBitrateKbps: version?.bitrate,
    sourceDurationMs: durationMs,
    sourceSizeBytes: versionSizeBytes(version),
  );
}

/// Show a dialog for selecting a media version.
/// Returns the selected index, or null if cancelled.
Future<int?> showVersionPickerDialog(BuildContext context, List<MediaVersion> versions, String title) {
  return showOptionPickerDialog<int>(
    context,
    title: title,
    options: List.generate(
      versions.length,
      (index) => (icon: Symbols.video_file_rounded, label: versions[index].displayLabel, value: index),
    ),
  );
}

/// Fetch media versions from a representative episode (first episode of first season).
Future<List<MediaVersion>?> fetchRepresentativeVersions(MediaServerClient client, MediaItem metadata) async {
  try {
    String? episodeRatingKey;

    if (metadata.kind == MediaKind.season) {
      final firstEpisode = await fetchFirstEpisodeForSeason(
        client,
        metadata.id,
        seriesId: metadata.grandparentId ?? metadata.parentId,
      );
      episodeRatingKey = firstEpisode?.id;
    } else if (metadata.kind == MediaKind.show) {
      final seasons = await client.fetchChildren(metadata.id);
      final firstSeason = defaultPlaybackSeason(seasons);
      if (firstSeason != null) {
        final firstEpisode = await fetchFirstEpisodeForSeason(client, firstSeason.id, seriesId: metadata.id);
        episodeRatingKey = firstEpisode?.id;
      }
    }

    if (episodeRatingKey == null) return null;

    final fullMetadata = await client.fetchItem(episodeRatingKey);
    return fullMetadata?.mediaVersions;
  } catch (e) {
    appLogger.w('Failed to fetch representative versions', error: e);
    return null;
  }
}
