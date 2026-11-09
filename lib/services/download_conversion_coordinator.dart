import 'dart:async';

import '../database/app_database.dart';
import '../database/download_conversion_operations.dart';
import '../media/download_conversion.dart';
import '../media/media_server_client.dart';
import '../models/transcode_quality_preset.dart';
import '../utils/app_logger.dart';

/// Where a download's conversion stands for the download manager.
sealed class ConversionOutcome {
  const ConversionOutcome();
}

/// The server is still preparing the copy; a poll is scheduled.
final class ConversionWaiting extends ConversionOutcome {
  /// 0–100, or `null` before the server reports any.
  final int? percent;

  const ConversionWaiting(this.percent);
}

/// The copy is ready: download [url] as one file with [extension].
final class ConversionReady extends ConversionOutcome {
  final String url;
  final String extension;

  const ConversionReady({required this.url, required this.extension});
}

/// The conversion failed; the download fails with [message].
final class ConversionFailedOutcome extends ConversionOutcome {
  final String message;

  const ConversionFailedOutcome(this.message);
}

/// The download was replaced or removed while its conversion advanced.
final class ConversionSuperseded extends ConversionOutcome {
  const ConversionSuperseded();
}

/// Drives the server-side conversions of downloads that asked for a smaller
/// copy, so the download manager only asks "is the file ready yet?".
///
/// Downloads without a [DownloadConversions] row never reach this class past
/// one primary-key lookup.
class DownloadConversionCoordinator {
  DownloadConversionCoordinator(this._database, {this._pollDelay = const Duration(seconds: 5)});

  final AppDatabase _database;
  final Duration _pollDelay;
  final Map<String, Timer> _polls = {};
  bool _disposed = false;

  /// Downloads waiting for their next poll. The queue skips them meanwhile.
  Set<String> get waitingKeys => _polls.keys.toSet();

  /// Records the quality requested for a newly admitted download, replacing
  /// and discarding any earlier conversion. Original removes the row.
  Future<void> request(
    String globalKey,
    TranscodeQualityPreset quality, {
    required MediaServerClient client,
    required String? clientScopeId,
  }) async {
    cancelPoll(globalKey);
    final previous = await _database.getDownloadConversion(globalKey);
    if (previous == null && quality.isOriginal) return;
    if (previous?.state case final state?) await _discardState(state, client);
    if (quality.isOriginal || downloadConversionOf(client) == null) {
      await _database.deleteDownloadConversion(globalKey);
      return;
    }
    await _database.requestDownloadConversion(globalKey, quality: quality, clientScopeId: clientScopeId);
  }

  /// Whether [globalKey] downloads a converted copy.
  Future<bool> isConverted(String globalKey) async => await _database.getDownloadConversion(globalKey) != null;

  /// Advances the conversion of [row], or returns `null` when it downloads
  /// the original. [clientScopeId] is the scope [client] would record.
  /// [onPollDue] runs when the next poll is due.
  Future<ConversionOutcome?> advance(
    DownloadedMediaItem row,
    MediaServerClient client, {
    required String? clientScopeId,
    required void Function() onPollDue,
  }) async {
    final globalKey = row.globalKey;
    cancelPoll(globalKey);
    var conversion = await _database.getDownloadConversion(globalKey);
    if (conversion == null) return null;
    final quality = TranscodeQualityPreset.values.asNameMap()[conversion.quality];
    final service = downloadConversionOf(client);
    if (quality == null || quality.isOriginal || service == null) {
      return const ConversionFailedOutcome('This server cannot prepare a smaller copy');
    }

    if (conversion.clientScopeId != clientScopeId) {
      // A job belongs to the account that created it; another account
      // cannot poll or remove it, so this one starts over.
      await _database.requestDownloadConversion(globalKey, quality: quality, clientScopeId: clientScopeId);
      conversion = await _database.getDownloadConversion(globalKey);
      if (conversion == null) return const ConversionSuperseded();
    }

    var superseded = false;
    Future<void> persist(String state) async {
      if (await _database.updateDownloadConversionState(globalKey, state, quality: quality.name)) return;
      superseded = true;
      await service.discard(state);
    }

    final step = await service.advance(
      DownloadConversionRequest(
        itemId: row.ratingKey,
        mediaIndex: row.mediaIndex,
        mediaSourceId: row.mediaSourceId,
        quality: quality,
      ),
      state: conversion.state,
      persist: persist,
    );
    switch (step) {
      case DownloadConversionPreparing(:final state, :final progress):
        await persist(state);
        if (superseded) return const ConversionSuperseded();
        _schedulePoll(globalKey, onPollDue);
        return ConversionWaiting(progress == null ? null : (progress.clamp(0.0, 1.0) * 100).round());
      case DownloadConversionReady(:final state, :final url):
        await persist(state);
        if (superseded) return const ConversionSuperseded();
        return ConversionReady(url: url, extension: service.outputExtension);
      case DownloadConversionFailed(:final message):
        if (!await _database.updateDownloadConversionState(globalKey, null, quality: quality.name)) {
          return const ConversionSuperseded();
        }
        return ConversionFailedOutcome(message);
    }
  }

  /// Discards the server-side job of a download that is stored, cancelled or
  /// deleted. The row stays with the download, so playback and retries still
  /// know it is a converted copy. [clientFor] is only called when there is a
  /// job to discard.
  Future<void> discard(String globalKey, Future<MediaServerClient?> Function() clientFor) {
    cancelPoll(globalKey);
    return _release(globalKey, clientFor);
  }

  Future<void> _release(String globalKey, Future<MediaServerClient?> Function() clientFor) async {
    final conversion = await _database.getDownloadConversion(globalKey);
    final state = conversion?.state;
    if (conversion == null || state == null) return;
    await _database.updateDownloadConversionState(globalKey, null, quality: conversion.quality);
    final client = await clientFor();
    if (client != null) await _discardState(state, client);
  }

  /// Polls every waiting conversion now, for example when the app returns
  /// to the foreground after the OS suspended its timers.
  void pollWaitingNow() {
    final due = _polls.entries.toList();
    for (final entry in due) {
      entry.value.cancel();
      _polls.remove(entry.key);
    }
    final callbacks = _pollCallbacks.values.toSet();
    _pollCallbacks.clear();
    for (final callback in callbacks) {
      callback();
    }
  }

  final Map<String, void Function()> _pollCallbacks = {};

  void cancelPoll(String globalKey) {
    _polls.remove(globalKey)?.cancel();
    _pollCallbacks.remove(globalKey);
  }

  void _schedulePoll(String globalKey, void Function() onPollDue) {
    if (_disposed) return;
    _pollCallbacks[globalKey] = onPollDue;
    _polls[globalKey] = Timer(_pollDelay, () {
      _polls.remove(globalKey);
      _pollCallbacks.remove(globalKey);
      if (!_disposed) onPollDue();
    });
  }

  Future<void> _discardState(String state, MediaServerClient client) async {
    try {
      await downloadConversionOf(client)?.discard(state);
    } catch (error) {
      appLogger.w('Could not discard a server-side download conversion', error: error);
    }
  }

  void dispose() {
    _disposed = true;
    for (final timer in _polls.values) {
      timer.cancel();
    }
    _polls.clear();
    _pollCallbacks.clear();
  }
}
