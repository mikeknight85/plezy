/// What a Plex Media Server's root (`/`) MediaContainer reports for the
/// requesting token.
///
/// The connection race and [PlexClient]'s transcoder warm-up already fetch
/// `/`, so reading these fields costs no extra request.
class PlexRootCapabilities {
  /// Whether the server has video transcoding enabled.
  final bool? transcoderVideo;

  /// Whether the server lets this token download (Plex's "sync" permission).
  final bool? allowSync;

  /// The server version, such as `1.41.9.9961-46083195d`.
  final String? version;

  const PlexRootCapabilities({this.transcoderVideo, this.allowSync, this.version});

  /// The first server version with the `/downloadQueue` API (API 1.0.0).
  static const downloadQueueMinimumVersion = [1, 41, 9];

  /// Reads the capability fields from a root MediaContainer; `null` when
  /// [container] is not a map.
  static PlexRootCapabilities? fromMediaContainer(Object? container) {
    if (container is! Map) return null;
    final version = container['version'];
    return PlexRootCapabilities(
      transcoderVideo: parsePlexBool(container['transcoderVideo']),
      allowSync: parsePlexBool(container['allowSync']),
      version: version is String && version.trim().isNotEmpty ? version.trim() : null,
    );
  }

  /// Whether the server can prepare converted downloads for this token.
  ///
  /// Both conditions must be reported: an absent field never enables it.
  bool get supportsDownloadQueue => allowSync == true && isVersionAtLeast(version, downloadQueueMinimumVersion);

  /// Compares the leading numeric components of a Plex version string.
  static bool isVersionAtLeast(String? version, List<int> minimum) {
    if (version == null) return false;
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(version);
    if (match == null) return false;
    for (var i = 0; i < minimum.length; i++) {
      final component = int.parse(match.group(i + 1)!);
      if (component != minimum[i]) return component > minimum[i];
    }
    return true;
  }
}

/// Plex encodes booleans as `1`/`0`, `true`/`false`, or strings of either.
bool? parsePlexBool(Object? value) {
  return switch (value) {
    final bool b => b,
    final int n when n == 1 => true,
    final int n when n == 0 => false,
    final String s when s.trim().toLowerCase() == 'true' || s.trim() == '1' => true,
    final String s when s.trim().toLowerCase() == 'false' || s.trim() == '0' => false,
    _ => null,
  };
}
