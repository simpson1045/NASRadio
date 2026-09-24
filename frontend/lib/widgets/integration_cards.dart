import 'package:flutter/material.dart';

import '../services/admin_settings_service.dart';
import 'settings_section_card.dart';

/// The one list of integration cards, shared by the first-run wizard and
/// Settings → Integrations so the two never drift. Each card names the
/// setting keys it edits, the backend test service, and which unsaved
/// field values that test should send.
typedef SavedCallback = void Function(List<AdminSetting> updated);

enum IntegrationSection { library, downloads, metadata, server, livingRoom }

List<Widget> integrationCards(
  IntegrationSection section,
  Map<String, AdminSetting> schema,
  SavedCallback onSaved, {
  bool compact = false,
}) {
  SettingsSectionCard card({
    required String title,
    String? description,
    required List<String> keys,
    String? test,
    TestOverridesBuilder? overrides,
  }) =>
      SettingsSectionCard(
        title: title,
        description: description,
        keys: keys,
        schema: schema,
        testService: test,
        testOverrides: overrides,
        onSaved: onSaved,
        compact: compact,
      );

  switch (section) {
    case IntegrationSection.library:
      return [
        card(
          title: 'Music library',
          keys: const ['MUSIC_LIBRARY_PATH', 'PODCAST_DOWNLOAD_DIR'],
          test: 'library',
          overrides: (v) => {'path': v['MUSIC_LIBRARY_PATH']},
        ),
        card(
          title: 'Finished downloads',
          description: 'Where completed downloads appear as THIS server sees them.',
          keys: const ['DOWNLOADS_NASRADIO', 'DOWNLOADS_LIDARR'],
        ),
      ];
    case IntegrationSection.downloads:
      return [
        card(
          title: 'Transmission',
          keys: const [
            'TRANSMISSION_URL',
            'TRANSMISSION_USER',
            'TRANSMISSION_PASS',
            'TRANSMISSION_DOWNLOAD_DIR',
          ],
          test: 'transmission',
          overrides: (v) => {
            'url': v['TRANSMISSION_URL'],
            'user': v['TRANSMISSION_USER'],
            'password': v['TRANSMISSION_PASS'],
          },
        ),
        card(
          title: 'Prowlarr',
          keys: const ['PROWLARR_URL', 'PROWLARR_API_KEY'],
          test: 'prowlarr',
          overrides: (v) => {'url': v['PROWLARR_URL'], 'api_key': v['PROWLARR_API_KEY']},
        ),
        card(
          title: 'Lidarr',
          keys: const ['LIDARR_URL', 'LIDARR_API_KEY'],
          test: 'lidarr',
          overrides: (v) => {'url': v['LIDARR_URL'], 'api_key': v['LIDARR_API_KEY']},
        ),
      ];
    case IntegrationSection.metadata:
      return [
        card(
          title: 'Last.fm (artwork)',
          description: 'Album artwork lookups. Scrobbling is set up separately, above.',
          keys: const ['LASTFM_API_KEY'],
          test: 'lastfm',
          overrides: (v) => {'api_key': v['LASTFM_API_KEY']},
        ),
        card(
          title: 'fanart.tv (artist images)',
          keys: const ['FANART_API_KEY'],
          test: 'fanart',
          overrides: (v) => {'api_key': v['FANART_API_KEY']},
        ),
        card(
          title: 'Spotify',
          keys: const ['SPOTIFY_CLIENT_ID', 'SPOTIFY_CLIENT_SECRET', 'SPOTIFY_SP_DC'],
          test: 'spotify',
          overrides: (v) => {
            'client_id': v['SPOTIFY_CLIENT_ID'],
            'client_secret': v['SPOTIFY_CLIENT_SECRET'],
          },
        ),
        card(
          title: 'Podcast Index',
          keys: const ['PODCAST_INDEX_KEY', 'PODCAST_INDEX_SECRET'],
          test: 'podcast_index',
          overrides: (v) => {
            'api_key': v['PODCAST_INDEX_KEY'],
            'api_secret': v['PODCAST_INDEX_SECRET'],
          },
        ),
        card(
          title: 'AcoustID',
          keys: const ['ACOUSTID_API_KEY'],
          test: 'acoustid',
          overrides: (v) => {'api_key': v['ACOUSTID_API_KEY']},
        ),
      ];
    case IntegrationSection.server:
      return [
        card(
          title: 'Public address',
          keys: const ['PUBLIC_BASE_URL', 'CONTACT_EMAIL'],
          test: 'public_url',
          overrides: (v) => {'url': v['PUBLIC_BASE_URL']},
        ),
        card(
          title: 'Essentia analysis service',
          description: 'Genres, mood, BPM, key and ReplayGain. Without it those stay off.',
          keys: const ['ESSENTIA_SERVICE_URL'],
          test: 'essentia',
          overrides: (v) => {'url': v['ESSENTIA_SERVICE_URL']},
        ),
        card(
          title: 'Transcode service',
          description:
              'Pre-bakes mobile AAC copies. Without it the server transcodes with ffmpeg on demand.',
          keys: const ['TRANSCODE_SERVICE_URL'],
          test: 'transcode',
          overrides: (v) => {'url': v['TRANSCODE_SERVICE_URL']},
        ),
        card(
          title: 'YouTube downloads',
          keys: const ['YT_DLP_COOKIES_FILE', 'YT_DLP_COOKIES_FROM_BROWSER'],
        ),
      ];
    case IntegrationSection.livingRoom:
      return [
        card(
          title: 'Cast device',
          description:
              'Lets the server cast on its own (headless cast). Casting from the app works without this. '
              'A receiver app ID makes the app launch your custom receiver instead of the default one.',
          keys: const [
            'CAST_DEVICE_HOST',
            'CAST_DEVICE_WOL_MAC',
            'CAST_WOL_BROADCAST',
            'CAST_RECEIVER_APP_ID',
          ],
          test: 'cast_device',
          overrides: (v) => {'host': v['CAST_DEVICE_HOST']},
        ),
        card(
          title: 'AV receiver',
          keys: const ['DENON_HOST', 'DENON_TELNET_PORT', 'DENON_INPUT_CMD'],
          test: 'denon',
          overrides: (v) => {'host': v['DENON_HOST'], 'port': v['DENON_TELNET_PORT']},
        ),
      ];
  }
}
