import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/media/download_conversion.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/services/plex_download_conversion.dart';
import 'package:plezy/services/plex_download_queue_service.dart';

import '../test_helpers/media_items.dart';

class _FakeQueue implements PlexDownloadQueueService {
  int created = 0;
  final added = <({String queueId, String ratingKey, int mediaIndex, TranscodeQualityPreset quality})>[];
  final removed = <String>[];
  var statuses = <PlexDownloadQueueStatus>[PlexDownloadQueueStatus.processing];
  double? progress = 0.4;
  String itemKey = '/library/metadata/42';
  Object? createError;
  Object? getItemError;
  Object? addError;
  Object? decisionError;

  @override
  Future<String> create() async {
    if (createError case final error?) throw error;
    created++;
    return '${10 + created}';
  }

  @override
  Future<String> add(
    String queueId, {
    required String ratingKey,
    required int mediaIndex,
    required TranscodeQualityPreset quality,
  }) async {
    if (addError case final error?) {
      addError = null;
      throw error;
    }
    added.add((queueId: queueId, ratingKey: ratingKey, mediaIndex: mediaIndex, quality: quality));
    return '${100 + added.length}';
  }

  @override
  Future<PlexDownloadQueueItem> getItem(String queueId, String itemId) async {
    if (getItemError case final error?) {
      getItemError = null;
      throw error;
    }
    final status = statuses.length > 1 ? statuses.removeAt(0) : statuses.single;
    return PlexDownloadQueueItem(
      id: itemId,
      queueId: queueId,
      key: itemKey,
      status: status,
      progress: status == PlexDownloadQueueStatus.available ? 1 : progress,
      error: status == PlexDownloadQueueStatus.error ? 'Transcoder failed' : null,
    );
  }

  @override
  Future<PlexDownloadDecision> getDecision(String queueId, String itemId) async {
    if (decisionError case final error?) throw error;
    return const PlexDownloadDecision(container: 'mkv', videoCodec: 'h264', audioCodec: 'aac');
  }

  @override
  Future<void> remove(String queueId, String itemId) async => removed.add('$queueId/$itemId');

  @override
  String mediaUrl(String queueId, String itemId) => 'https://pms/downloadQueue/$queueId/item/$itemId/media';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MediaVersion _version(String id) => MediaVersion(id: id);

void main() {
  late _FakeQueue queue;
  late List<String> persisted;
  late bool rejected;
  MediaItem? item;

  PlexDownloadConversion conversion() =>
      PlexDownloadConversion(queue, fetchItem: (_) async => item, onRejected: () => rejected = true);

  Future<void> persist(String state) async => persisted.add(state);

  const request = DownloadConversionRequest(
    itemId: '42',
    mediaIndex: 0,
    mediaSourceId: null,
    quality: TranscodeQualityPreset.p720_2mbps,
  );

  setUp(() {
    queue = _FakeQueue();
    persisted = [];
    rejected = false;
    item = null;
  });

  test('starts a job, persisting the queue and item before polling', () async {
    final step = await conversion().advance(request, persist: persist);

    expect(step, isA<DownloadConversionPreparing>());
    expect((step as DownloadConversionPreparing).progress, 0.4);
    expect(queue.created, 1);
    expect(queue.added.single.quality, TranscodeQualityPreset.p720_2mbps);
    expect(queue.added.single.ratingKey, '42');
    // The queue is saved before the item is added, and the item before polling.
    expect(persisted, hasLength(2));
    expect(persisted.first, contains('"queueId":"11"'));
    expect(persisted.first, isNot(contains('itemId')));
    expect(persisted.last, contains('"itemId":"101"'));
  });

  test('continues from saved state without creating a new job', () async {
    final first = await conversion().advance(request, persist: persist) as DownloadConversionPreparing;
    queue.statuses = [PlexDownloadQueueStatus.available];

    final step = await conversion().advance(request, state: first.state, persist: persist);

    expect(step, isA<DownloadConversionReady>());
    expect((step as DownloadConversionReady).url, 'https://pms/downloadQueue/11/item/101/media');
    expect(queue.created, 1);
    expect(queue.added, hasLength(1));
  });

  test('binds the job to the stored source version, not its old position', () async {
    item = testMediaItem(id: '42', mediaVersions: [_version('a'), _version('b'), _version('c')]);
    const bySource = DownloadConversionRequest(
      itemId: '42',
      mediaIndex: 0,
      mediaSourceId: 'c',
      quality: TranscodeQualityPreset.p720_2mbps,
    );

    await conversion().advance(bySource, persist: persist);

    expect(queue.added.single.mediaIndex, 2);
  });

  test('fails when the selected version is gone from the server', () async {
    item = testMediaItem(id: '42', mediaVersions: [_version('a')]);
    const bySource = DownloadConversionRequest(
      itemId: '42',
      mediaIndex: 0,
      mediaSourceId: 'gone',
      quality: TranscodeQualityPreset.p720_2mbps,
    );

    expect(await conversion().advance(bySource, persist: persist), isA<DownloadConversionFailed>());
    expect(queue.added, isEmpty);
  });

  test('re-adds an expired item, then gives up after the restart limit', () async {
    queue.statuses = [PlexDownloadQueueStatus.expired];

    final step = await conversion().advance(request, persist: persist);

    expect(step, isA<DownloadConversionFailed>());
    // The first item plus one per allowed restart, each removed when it expired.
    expect(queue.added, hasLength(1 + PlexDownloadConversion.maxRestarts));
    expect(queue.removed, hasLength(1 + PlexDownloadConversion.maxRestarts));
    // Every restart reuses the queue.
    expect(queue.created, 1);
  });

  test('re-adds an item the server no longer knows', () async {
    final first = await conversion().advance(request, persist: persist) as DownloadConversionPreparing;
    queue.getItemError = MediaServerHttpException(
      type: MediaServerHttpErrorType.unknown,
      message: 'gone',
      statusCode: 404,
    );

    final step = await conversion().advance(request, state: first.state, persist: persist);

    expect(step, isA<DownloadConversionPreparing>());
    expect(queue.added, hasLength(2));
    expect((step as DownloadConversionPreparing).state, contains('"restarts":1'));
  });

  test('a saved queue the server has dropped is replaced by a new one', () async {
    queue.addError = MediaServerHttpException(type: MediaServerHttpErrorType.unknown, message: 'gone', statusCode: 404);

    final step = await conversion().advance(request, state: '{"queueId":"7"}', persist: persist);

    expect(step, isA<DownloadConversionPreparing>());
    expect(queue.created, 1);
    expect(queue.added.last.queueId, '11');
  });

  test('a server error discards the job and reports Plex\'s reason', () async {
    queue.statuses = [PlexDownloadQueueStatus.error];

    final step = await conversion().advance(request, persist: persist);

    expect(step, isA<DownloadConversionFailed>());
    expect((step as DownloadConversionFailed).message, 'Transcoder failed');
    expect(queue.removed, ['11/101']);
  });

  test('a decision that is not the requested format fails and discards the job', () async {
    queue.statuses = [PlexDownloadQueueStatus.available];
    queue.decisionError = const FormatException('not h264');

    final step = await conversion().advance(request, persist: persist);

    expect(step, isA<DownloadConversionFailed>());
    expect(queue.removed, ['11/101']);
  });

  test('a prepared copy of another video is never downloaded', () async {
    queue.itemKey = '/library/metadata/999';

    expect(await conversion().advance(request, persist: persist), isA<DownloadConversionFailed>());
    expect(queue.removed, ['11/101']);
  });

  for (final status in [401, 403]) {
    test('a refused queue (HTTP $status) withdraws the offer', () async {
      queue.createError = MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'refused',
        statusCode: status,
      );

      final step = await conversion().advance(request, persist: persist);

      expect(step, isA<DownloadConversionFailed>());
      expect(rejected, isTrue);
    });
  }

  test('a server without the queue endpoint (404 on create) withdraws the offer', () async {
    queue.createError = MediaServerHttpException(
      type: MediaServerHttpErrorType.unknown,
      message: 'missing',
      statusCode: 404,
    );

    expect(await conversion().advance(request, persist: persist), isA<DownloadConversionFailed>());
    expect(rejected, isTrue);
  });

  test('a transient server error is left to the download manager to retry', () async {
    queue.createError = MediaServerHttpException(
      type: MediaServerHttpErrorType.unknown,
      message: 'busy',
      statusCode: 503,
    );

    await expectLater(conversion().advance(request, persist: persist), throwsA(isA<MediaServerHttpException>()));
    expect(rejected, isFalse);
  });

  test('discard removes the job and never throws', () async {
    final first = await conversion().advance(request, persist: persist) as DownloadConversionPreparing;

    await conversion().discard(first.state);
    await conversion().discard('{"queueId":"11"}');

    expect(queue.removed, ['11/101']);
  });

  test('prepared copies are MKV files', () {
    expect(conversion().outputExtension, 'mkv');
  });
}
