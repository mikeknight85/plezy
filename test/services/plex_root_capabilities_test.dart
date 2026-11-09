import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/plex_root_capabilities.dart';

void main() {
  group('PlexRootCapabilities', () {
    test('reads allowSync, version and transcoderVideo from the root container', () {
      final capabilities = PlexRootCapabilities.fromMediaContainer({
        'allowSync': true,
        'transcoderVideo': 1,
        'version': '1.41.9.9961-46083195d',
      })!;
      expect(capabilities.allowSync, isTrue);
      expect(capabilities.transcoderVideo, isTrue);
      expect(capabilities.version, '1.41.9.9961-46083195d');
      expect(capabilities.supportsDownloadQueue, isTrue);
    });

    test('accepts Plex string and integer booleans', () {
      expect(PlexRootCapabilities.fromMediaContainer({'allowSync': '1'})!.allowSync, isTrue);
      expect(PlexRootCapabilities.fromMediaContainer({'allowSync': 0})!.allowSync, isFalse);
      expect(PlexRootCapabilities.fromMediaContainer({'allowSync': 'false'})!.allowSync, isFalse);
      expect(PlexRootCapabilities.fromMediaContainer({'allowSync': 'maybe'})!.allowSync, isNull);
    });

    test('is not a capability source when the container is missing', () {
      expect(PlexRootCapabilities.fromMediaContainer(null), isNull);
      expect(PlexRootCapabilities.fromMediaContainer('not a map'), isNull);
    });

    test('offers the download queue only with allowSync on PMS 1.41.9 or newer', () {
      bool supports({Object? allowSync, String? version}) => PlexRootCapabilities.fromMediaContainer({
        'allowSync': ?allowSync,
        'version': ?version,
      })!.supportsDownloadQueue;

      expect(supports(allowSync: 1, version: '1.43.0.10162-abc'), isTrue);
      expect(supports(allowSync: 1, version: '1.42.0.1-abc'), isTrue);
      expect(supports(allowSync: 1, version: '2.0.0.0-abc'), isTrue);
      // Older servers have no /downloadQueue.
      expect(supports(allowSync: 1, version: '1.41.8.9834-abc'), isFalse);
      expect(supports(allowSync: 1, version: '1.40.5.0-abc'), isFalse);
      // A user who may not download never sees the choice.
      expect(supports(allowSync: 0, version: '1.43.0.10162-abc'), isFalse);
      // Absent fields never enable it.
      expect(supports(version: '1.43.0.10162-abc'), isFalse);
      expect(supports(allowSync: 1), isFalse);
      expect(supports(allowSync: 1, version: 'unknown'), isFalse);
    });
  });
}
