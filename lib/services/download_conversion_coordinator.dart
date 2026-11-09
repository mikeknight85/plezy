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
/// Every change to one download's conversion runs under a per-download lock,
/// and [invalidate] makes any step still in flight for it stale: a stale step
/// never records its job, and removes the job unless it is the one already
/// recorded. A cancel, delete, pause or new request therefore never leaks a
/// server-side job or lets an old step overwrite a newer request.
class DownloadConversionCoordinator {
  DownloadConversionCoordinator(this._database, {this._pollDelay = const Duration(seconds: 5)});

  final AppDatabase _database;
  final Duration _pollDelay;
  final Map<String, Timer> _polls = {};
  final Map<String, int> _generations = {};
  final Map<String, Future<void>> _locks = {};
  bool _disposed = false;

  /// Downloads waiting for their next poll. The queue skips them meanwhile.
  Set<String> get waitingKeys => _polls.keys.toSet();

  /// Makes every step in flight for [globalKey] stale and stops its polling.
  /// The recorded job is kept, so a paused download can continue it later.
  void invalidate(String globalKey) {
    cancelPoll(globalKey);
    _generations.update(globalKey, (generation) => generation + 1, ifAbsent: () => 1);
  }

  /// Admits a download through [insert] and records [quality] for it in the
  /// same transaction, so the queue can never pick up the row before its
  /// quality is known. The previous request's job, if any, is discarded.
  /// [admitted] says whether [insert]'s result replaced the download.
  Future<T> admit<T>(
    String globalKey,
    TranscodeQualityPreset quality, {
    required MediaServerClient client,
    required String? clientScopeId,
    required Future<T> Function() insert,
    required bool Function(T result) admitted,
  }) {
    // Only a client that offers conversion right now may start one, so a
    // stale or crafted quality never reaches a server without the feature.
    final convert = !quality.isOriginal && offersDownloadConversion(client);
    invalidate(globalKey);
    return _locked(globalKey, () async {
      DownloadConversionRow? previous;
      late T result;
      await _database.transaction(() async {
        previous = await _database.getDownloadConversion(globalKey);
        result = await insert();
        if (!admitted(result)) return;
        if (convert) {
          await _database.requestDownloadConversion(globalKey, quality: quality, clientScopeId: clientScopeId);
        } else if (previous != null) {
          await _database.deleteDownloadConversion(globalKey);
        }
      });
      if (admitted(result)) {
        if (previous?.state case final state?) await _discardState(state, client);
      }
      return result;
    });
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
    final generation = _generations[globalKey] ?? 0;
    bool current() => !_disposed && (_generations[globalKey] ?? 0) == generation;

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
      final restarted = await _locked(globalKey, () async {
        if (!current()) return false;
        await _database.requestDownloadConversion(globalKey, quality: quality, clientScopeId: clientScopeId);
        return true;
      });
      if (!restarted) return const ConversionSuperseded();
      conversion = await _database.getDownloadConversion(globalKey);
      if (conversion == null) return const ConversionSuperseded();
    }

    Future<void> persist(String state) => _locked(globalKey, () async {
      if (current()) {
        await _database.updateDownloadConversionState(globalKey, state, quality: quality.name);
        return;
      }
      // Stale: never record this job, and remove it unless it is the job
      // the row already holds (a paused download keeps that one).
      final recorded = (await _database.getDownloadConversion(globalKey))?.state;
      if (recorded != state) await _discardState(state, client);
      throw const _StaleConversionStep();
    });

    try {
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
          _schedulePoll(globalKey, onPollDue);
          return ConversionWaiting(progress == null ? null : (progress.clamp(0.0, 1.0) * 100).round());
        case DownloadConversionReady(:final state, :final url):
          await persist(state);
          return ConversionReady(url: url, extension: service.outputExtension);
        case DownloadConversionFailed(:final message):
          final recorded = await _locked(globalKey, () async {
            if (!current()) return false;
            await _database.updateDownloadConversionState(globalKey, null, quality: quality.name);
            return true;
          });
          return recorded ? ConversionFailedOutcome(message) : const ConversionSuperseded();
      }
    } on _StaleConversionStep {
      return const ConversionSuperseded();
    }
  }

  /// Discards the server-side job of a download that is stored, cancelled or
  /// deleted, and makes steps in flight for it stale. The row stays with the
  /// download, so playback and retries still know it is a converted copy.
  /// [clientFor] is only called when there is a job to discard.
  Future<void> discard(String globalKey, Future<MediaServerClient?> Function() clientFor) {
    invalidate(globalKey);
    return _locked(globalKey, () async {
      final conversion = await _database.getDownloadConversion(globalKey);
      final state = conversion?.state;
      if (conversion == null || state == null) return;
      await _database.updateDownloadConversionState(globalKey, null, quality: conversion.quality);
      final client = await clientFor();
      if (client != null) await _discardState(state, client);
    });
  }

  /// Runs [body] after every earlier locked operation for [globalKey].
  Future<T> _locked<T>(String globalKey, Future<T> Function() body) {
    final previous = _locks[globalKey] ?? Future<void>.value();
    final result = previous.then((_) => body());
    final done = result.then<void>((_) {}, onError: (_) {});
    _locks[globalKey] = done;
    unawaited(
      done.then((_) {
        if (identical(_locks[globalKey], done)) _locks.remove(globalKey);
      }),
    );
    return result;
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

/// Thrown out of a stale step's persist call to stop the backend at once.
class _StaleConversionStep implements Exception {
  const _StaleConversionStep();
}
