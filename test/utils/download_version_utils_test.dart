import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/download_conversion.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/utils/download_version_utils.dart';
import 'package:plezy/utils/quality_preset_labels.dart';

/// A client like today's: no download conversion at all.
class _PlainClient implements MediaServerClient {
  _PlainClient(this.backend);

  @override
  final MediaBackend backend;

  @override
  Future<MediaItem?> fetchItem(String id) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A client whose server may or may not offer conversion right now.
class _ConversionClient extends _PlainClient implements DownloadConversionSource {
  _ConversionClient({required this.offersDownloadConversion}) : super(MediaBackend.plex);

  @override
  final bool offersDownloadConversion;

  @override
  DownloadConversion get downloadConversion => throw UnimplementedError();
}

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  Future<void> tapDownload(
    WidgetTester tester, {
    required MediaServerClient client,
    MediaKind kind = MediaKind.movie,
    required ValueChanged<DownloadVersionConfig?> onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => onResult(
                await resolveDownloadVersion(
                  context,
                  MediaItem(id: 'item', backend: client.backend, kind: kind),
                  client,
                ),
              ),
              child: const Text('Download'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
  }

  group('without download conversion nothing changes', () {
    for (final (label, client) in [
      ('a Plex server without the offer', _ConversionClient(offersDownloadConversion: false)),
      ('a backend without conversion', _PlainClient(MediaBackend.jellyfin)),
    ]) {
      testWidgets('$label downloads the original without asking', (tester) async {
        DownloadVersionConfig? result;
        await tapDownload(tester, client: client, onResult: (value) => result = value);

        expect(find.text(t.downloads.selectQuality), findsNothing);
        expect(find.byType(Dialog), findsNothing);
        expect(result, isNotNull);
        expect(result!.quality, TranscodeQualityPreset.original);
        expect(result!.mediaIndex, 0);
      });
    }
  });

  group('with download conversion', () {
    testWidgets('asks for a quality, original first, and returns the pick', (tester) async {
      DownloadVersionConfig? result;
      await tapDownload(
        tester,
        client: _ConversionClient(offersDownloadConversion: true),
        onResult: (value) => result = value,
      );

      expect(find.text(t.downloads.selectQuality), findsOneWidget);
      expect(find.text(t.downloads.preparationBackgroundHint), findsOneWidget);
      final original = find.text(qualityPresetLabel(TranscodeQualityPreset.original));
      final highest = find.text(qualityPresetLabel(TranscodeQualityPreset.p1080_20mbps));
      expect(tester.getTopLeft(original).dy, lessThan(tester.getTopLeft(highest).dy));

      final selected = find.text(qualityPresetLabel(TranscodeQualityPreset.p720_2mbps));
      await tester.ensureVisible(selected);
      await tester.tap(selected);
      await tester.pumpAndSettle();

      expect(result?.quality, TranscodeQualityPreset.p720_2mbps);
    });

    testWidgets('dismissing the quality choice cancels the download', (tester) async {
      var completed = false;
      DownloadVersionConfig? result;
      await tapDownload(
        tester,
        client: _ConversionClient(offersDownloadConversion: true),
        onResult: (value) {
          completed = true;
          result = value;
        },
      );

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(completed, isTrue);
      expect(result, isNull);
    });

    testWidgets('music never asks for a quality', (tester) async {
      DownloadVersionConfig? result;
      await tapDownload(
        tester,
        client: _ConversionClient(offersDownloadConversion: true),
        kind: MediaKind.album,
        onResult: (value) => result = value,
      );

      expect(find.text(t.downloads.selectQuality), findsNothing);
      expect(result?.quality, TranscodeQualityPreset.original);
    });
  });
}
