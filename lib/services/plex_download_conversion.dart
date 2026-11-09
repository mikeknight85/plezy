import 'dart:convert';

import '../exceptions/media_server_exceptions.dart';
import '../media/download_conversion.dart';
import '../media/media_item.dart';
import '../utils/app_logger.dart';
import 'plex_download_queue_service.dart';

/// [DownloadConversion] over Plex's download queue (PMS 1.41.9+).
///
/// The state is the queue and item IDs, so the server-side job survives app
/// restarts and suspension: Plex keeps converting while the app is away.
class PlexDownloadConversion implements DownloadConversion {
  final PlexDownloadQueueService _queue;

  /// The item's current metadata, to find a source version by its stable ID.
  final Future<MediaItem?> Function(String itemId) _fetchItem;

  /// Called when the server refuses the download queue (401/403/404 on
  /// creation), so the quality choice is no longer offered.
  final void Function() _onRejected;

  PlexDownloadConversion(this._queue, {required this._fetchItem, required this._onRejected});

  /// Server items that expired before download are re-added this many times.
  static const maxRestarts = 2;

  @override
  String get outputExtension => PlexDownloadQueueService.outputContainer;

  @override
  Future<DownloadConversionStep> advance(
    DownloadConversionRequest request, {
    String? state,
    required Future<void> Function(String state) persist,
  }) async {
    var current = _PlexConversionState.decode(state);
    try {
      if (current.queueId == null) {
        final String queueId;
        try {
          queueId = await _queue.create();
        } on MediaServerHttpException catch (error) {
          // A server that advertises downloads but has no queue endpoint.
          if (error.statusCode == 404) return _rejected(current, error);
          rethrow;
        }
        current = current.copyWith(queueId: queueId);
        await persist(current.encode());
      }
      if (current.itemId == null) {
        final mediaIndex = await _resolveMediaIndex(request);
        final String itemId;
        try {
          itemId = await _queue.add(
            current.queueId!,
            ratingKey: request.itemId,
            mediaIndex: mediaIndex,
            quality: request.quality,
          );
        } on MediaServerHttpException catch (error) {
          // A saved queue the server has since dropped: start a new one.
          if (error.statusCode != 404 || state == null) rethrow;
          return await _restart(request, current, persist, keepQueue: false);
        }
        current = current.copyWith(itemId: itemId);
        await persist(current.encode());
      }

      final PlexDownloadQueueItem item;
      try {
        item = await _queue.getItem(current.queueId!, current.itemId!);
      } on MediaServerHttpException catch (error) {
        if (error.statusCode != 404 && error.statusCode != 410) rethrow;
        // The item, or its whole queue, is gone from the server.
        return await _restart(request, current, persist, keepQueue: false);
      }
      if (item.key != '/library/metadata/${Uri.encodeComponent(request.itemId)}') {
        await discard(current.encode());
        return const DownloadConversionFailed('Plex prepared a different video');
      }
      switch (item.status) {
        case PlexDownloadQueueStatus.expired:
          await _removeQuietly(current);
          return await _restart(request, current, persist, keepQueue: true);
        case PlexDownloadQueueStatus.error:
          await _removeQuietly(current);
          return DownloadConversionFailed(item.error ?? 'Plex could not prepare the download');
        case PlexDownloadQueueStatus.available:
          await _queue.getDecision(current.queueId!, current.itemId!);
          return DownloadConversionReady(
            state: current.encode(),
            url: _queue.mediaUrl(current.queueId!, current.itemId!),
          );
        case PlexDownloadQueueStatus.deciding:
        case PlexDownloadQueueStatus.waiting:
        case PlexDownloadQueueStatus.processing:
          return DownloadConversionPreparing(state: current.encode(), progress: item.progress);
      }
    } on MediaServerHttpException catch (error) {
      // The server advertised downloads but refuses the queue to this
      // account, for example without Plex Pass.
      if (current.itemId == null && const {401, 403}.contains(error.statusCode)) return _rejected(current, error);
      rethrow;
    } on FormatException catch (error) {
      await _removeQuietly(current);
      return DownloadConversionFailed(error.message);
    }
  }

  /// Stops offering the quality choice; this download fails.
  DownloadConversionStep _rejected(_PlexConversionState current, MediaServerHttpException error) {
    _onRejected();
    return DownloadConversionFailed('Plex refused the download queue (HTTP ${error.statusCode})');
  }

  Future<DownloadConversionStep> _restart(
    DownloadConversionRequest request,
    _PlexConversionState expired,
    Future<void> Function(String state) persist, {
    required bool keepQueue,
  }) async {
    if (expired.restarts >= maxRestarts) {
      return const DownloadConversionFailed('Plex removed the prepared download before it finished');
    }
    final next = _PlexConversionState(queueId: keepQueue ? expired.queueId : null, restarts: expired.restarts + 1);
    await persist(next.encode());
    return advance(request, state: next.encode(), persist: persist);
  }

  /// Plex's mediaIndex is positional, and versions can be reordered while a
  /// download waits, so a stored source ID wins over the queued position.
  Future<int> _resolveMediaIndex(DownloadConversionRequest request) async {
    final sourceId = request.mediaSourceId;
    if (sourceId == null || sourceId.isEmpty) return request.mediaIndex;
    final versions = (await _fetchItem(request.itemId))?.mediaVersions;
    final index = versions?.indexWhere((version) => version.id == sourceId) ?? -1;
    if (index < 0) throw const FormatException('The selected version is no longer on the server');
    return index;
  }

  @override
  Future<void> discard(String state) => _removeQuietly(_PlexConversionState.decode(state));

  Future<void> _removeQuietly(_PlexConversionState state) async {
    final queueId = state.queueId;
    final itemId = state.itemId;
    if (queueId == null || itemId == null) return;
    try {
      await _queue.remove(queueId, itemId);
    } catch (error) {
      appLogger.w('Could not remove a prepared Plex download', error: error);
    }
  }
}

class _PlexConversionState {
  final String? queueId;
  final String? itemId;
  final int restarts;

  const _PlexConversionState({this.queueId, this.itemId, this.restarts = 0});

  static _PlexConversionState decode(String? encoded) {
    if (encoded == null) return const _PlexConversionState();
    final json = jsonDecode(encoded);
    if (json is! Map) return const _PlexConversionState();
    final restarts = json['restarts'];
    return _PlexConversionState(
      queueId: json['queueId'] as String?,
      itemId: json['itemId'] as String?,
      restarts: restarts is int ? restarts : 0,
    );
  }

  _PlexConversionState copyWith({String? queueId, String? itemId}) =>
      _PlexConversionState(queueId: queueId ?? this.queueId, itemId: itemId ?? this.itemId, restarts: restarts);

  String encode() => jsonEncode({'queueId': ?queueId, 'itemId': ?itemId, 'restarts': restarts});
}
