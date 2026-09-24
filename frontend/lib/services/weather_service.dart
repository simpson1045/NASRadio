import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audioplayers/audioplayers.dart' as ap;
import 'audio_player_service.dart';

/// Current weather observation data from NWS
class WeatherData {
  final double? temperatureF;
  final double? feelsLikeF;
  final double? humidity;
  final double? windSpeedMph;
  final String? windDirection;
  final String description;
  final String emoji;
  final bool isDaytime;
  final String locationName;
  final DateTime timestamp;

  WeatherData({
    this.temperatureF,
    this.feelsLikeF,
    this.humidity,
    this.windSpeedMph,
    this.windDirection,
    required this.description,
    required this.emoji,
    required this.isDaytime,
    required this.locationName,
    required this.timestamp,
  });
}

/// NWS weather alert
class WeatherAlert {
  final String id;
  final String event;
  final String headline;
  final String severity; // Extreme, Severe, Moderate, Minor, Unknown
  final String urgency;  // Immediate, Expected, Future, Unknown
  final DateTime? onset;
  final DateTime? expires;
  final String description;

  WeatherAlert({
    required this.id,
    required this.event,
    required this.headline,
    required this.severity,
    required this.urgency,
    this.onset,
    this.expires,
    required this.description,
  });

  bool get isSevere =>
      severity == 'Extreme' || severity == 'Severe';
}

/// Location search result from Nominatim geocoding
class LocationResult {
  final String city;
  final String state;
  final String displayName;
  final double lat;
  final double lon;

  LocationResult({
    required this.city,
    required this.state,
    required this.displayName,
    required this.lat,
    required this.lon,
  });

  String get shortName => state.isNotEmpty ? '$city, $state' : city;
}

class WeatherService extends ChangeNotifier {
  // weather.gov and Nominatim require an identifying User-Agent with a contact.
  static const String _userAgent = '(NASRadio, https://github.com/simpson1045/NASRadio)';
  static const Duration _observationInterval = Duration(minutes: 10);
  static const Duration _alertInterval = Duration(minutes: 2);

  // Audio player for volume ducking during TTS
  AudioPlayerService? audioPlayerService;

  // TTS engine
  FlutterTts? _tts;
  bool _ttsInitialized = false;
  bool _announcing = false;
  final List<WeatherAlert> _announcementQueue = [];
  // Alert IDs we've already spoken — persisted so the same active alert (e.g. a
  // multi-day fire weather watch) isn't re-announced on every single app open.
  List<String> _announcedAlertIds = [];

  // Chime player
  final ap.AudioPlayer _chimePlayer = ap.AudioPlayer();

  // Ambient sound player
  final ap.AudioPlayer _ambientPlayer = ap.AudioPlayer();
  bool _ambientPlaying = false;

  // Current state
  WeatherData? _currentWeather;
  WeatherData? get currentWeather => _currentWeather;

  bool _enabled = false;
  bool get enabled => _enabled;

  bool _loading = false;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  // Location
  double? _latitude;
  double? _longitude;
  String _locationName = '';
  bool _useGps = true;

  double? get latitude => _latitude;
  double? get longitude => _longitude;
  String get locationName => _locationName;
  bool get useGps => _useGps;

  // NWS cached data
  String? _observationStationUrl;

  // Alerts
  final List<WeatherAlert> _alertHistory = [];
  List<WeatherAlert> get alertHistory => List.unmodifiable(_alertHistory);
  final Set<String> _seenAlertIds = {};
  WeatherAlert? _latestAlert;
  WeatherAlert? get latestAlert => _latestAlert;

  // Alert settings
  String _alertMode = 'voice_and_banner'; // voice_and_banner, banner_only, voice_only, off
  String get alertMode => _alertMode;
  String _alertSeverity = 'severe_only'; // severe_only, all
  String get alertSeverity => _alertSeverity;
  bool _ambientSounds = false;
  bool get ambientSounds => _ambientSounds;

  // Callback for new alerts (used by UI for banners and TTS)
  void Function(WeatherAlert alert)? onNewAlert;

  // Timers
  Timer? _observationTimer;
  Timer? _alertTimer;
  int _consecutiveErrors = 0;
  static const int _maxBackoffMinutes = 30;

  // HTTP client
  final http.Client _httpClient = http.Client();

  /// Initialize the service — load prefs, start polling if enabled
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool('weather_enabled') ?? false;
    _useGps = prefs.getBool('weather_use_gps') ??
        (Platform.isAndroid || Platform.isIOS);
    _latitude = prefs.getDouble('weather_lat');
    _longitude = prefs.getDouble('weather_lon');
    _locationName = prefs.getString('weather_location_name') ?? '';
    _alertMode = prefs.getString('weather_alert_mode') ?? 'voice_and_banner';
    _alertSeverity =
        prefs.getString('weather_alert_severity') ?? 'severe_only';
    _ambientSounds = prefs.getBool('weather_ambient_sounds') ?? false;
    _announcedAlertIds = prefs.getStringList('weather_announced_alert_ids') ?? [];

    if (_enabled) {
      _startPolling();
    }
  }

  /// Enable or disable weather
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('weather_enabled', value);

    if (value) {
      _startPolling();
    } else {
      _stopPolling();
      _currentWeather = null;
      _latestAlert = null;
    }
    notifyListeners();
  }

  /// Update alert mode setting
  Future<void> setAlertMode(String mode) async {
    _alertMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('weather_alert_mode', mode);
    notifyListeners();
  }

  /// Update alert severity filter
  Future<void> setAlertSeverity(String severity) async {
    _alertSeverity = severity;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('weather_alert_severity', severity);
    notifyListeners();
  }

  /// Update ambient sounds setting
  Future<void> setAmbientSounds(bool value) async {
    _ambientSounds = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('weather_ambient_sounds', value);
    // Start or stop ambient sounds based on current conditions
    if (_currentWeather != null) {
      _updateAmbientSounds(_currentWeather!.description);
    }
    notifyListeners();
  }

  /// Set GPS usage preference
  Future<void> setUseGps(bool value) async {
    _useGps = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('weather_use_gps', value);
    if (value && _enabled) {
      // Re-resolve location from GPS
      _observationStationUrl = null;
      _fetchWeather();
    }
    notifyListeners();
  }

  /// Manually set location (for desktop or when GPS is off)
  Future<void> setManualLocation(double lat, double lon) async {
    _latitude = lat;
    _longitude = lon;
    _observationStationUrl = null; // Force re-resolve
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('weather_lat', lat);
    await prefs.setDouble('weather_lon', lon);
    if (_enabled) {
      _fetchWeather();
    }
    notifyListeners();
  }

  /// Search for a location by city/state name using Nominatim geocoding
  Future<List<LocationResult>> searchLocation(String query) async {
    if (query.trim().length < 2) return [];

    try {
      final encoded = Uri.encodeComponent(query.trim());
      final response = await http.Client().get(
        Uri.parse(
          'https://nominatim.openstreetmap.org/search'
          '?q=$encoded'
          '&format=json'
          '&countrycodes=us'
          '&limit=5'
          '&addressdetails=1',
        ),
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/json',
        },
      );

      if (response.statusCode != 200) return [];

      final data = json.decode(response.body) as List;
      final results = <LocationResult>[];

      for (final item in data) {
        final lat = double.tryParse(item['lat']?.toString() ?? '');
        final lon = double.tryParse(item['lon']?.toString() ?? '');
        if (lat == null || lon == null) continue;

        final address = item['address'] as Map<String, dynamic>? ?? {};
        final city = address['city'] ??
            address['town'] ??
            address['village'] ??
            address['hamlet'] ??
            address['county'] ??
            '';
        final state = address['state'] ?? '';

        if (city.toString().isEmpty) continue;

        results.add(LocationResult(
          city: city.toString(),
          state: state.toString(),
          displayName: item['display_name']?.toString() ?? '',
          lat: lat,
          lon: lon,
        ));
      }

      return results;
    } catch (e) {
      print('Location search error: $e');
      return [];
    }
  }

  /// Set location from a search result
  Future<void> setLocationFromSearch(LocationResult result) async {
    _latitude = result.lat;
    _longitude = result.lon;
    _locationName = result.shortName;
    _observationStationUrl = null; // Force re-resolve

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('weather_lat', result.lat);
    await prefs.setDouble('weather_lon', result.lon);
    await prefs.setString('weather_location_name', _locationName);

    if (_enabled) {
      _fetchWeather();
      _fetchAlerts();
    }
    notifyListeners();
  }

  /// Dismiss the latest alert banner
  void dismissAlert() {
    _latestAlert = null;
    notifyListeners();
  }

  void _startPolling() {
    // Fetch immediately
    _fetchWeather();
    _fetchAlerts();

    // Set up periodic polling
    _observationTimer?.cancel();
    _observationTimer = Timer.periodic(_observationInterval, (_) {
      _fetchWeather();
    });
    _alertTimer?.cancel();
    _alertTimer = Timer.periodic(_alertInterval, (_) {
      _fetchAlerts();
    });
  }

  void _stopPolling() {
    _observationTimer?.cancel();
    _observationTimer = null;
    _alertTimer?.cancel();
    _alertTimer = null;
  }

  /// Resolve GPS location on mobile
  Future<bool> _resolveGpsLocation() async {
    if (!_useGps || !(Platform.isAndroid || Platform.isIOS)) {
      // Desktop or GPS disabled — fall back to a manually-set location.
      // If neither is configured, set an explicit error so the dashboard
      // shows the "Set location in Settings" banner instead of silently
      // hiding the whole weather widget (which is what was happening
      // pre-2026-05-26: enabled but invisible, no message).
      if (_latitude == null || _longitude == null) {
        _error = 'Location not set';
        return false;
      }
      return true;
    }

    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _error = 'Location services disabled';
        return false;
      }

      // Check/request permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _error = 'Location permission denied';
          return false;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        _error = 'Location permission permanently denied';
        return false;
      }

      // Get position
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low, // City-level is fine for weather
          timeLimit: Duration(seconds: 10),
        ),
      );

      _latitude = position.latitude;
      _longitude = position.longitude;

      // Save for offline use
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('weather_lat', _latitude!);
      await prefs.setDouble('weather_lon', _longitude!);

      _error = null;
      return true;
    } catch (e) {
      _error = 'Could not get location';
      print('Weather GPS error: $e');
      return false;
    }
  }

  /// Look up the NWS observation station for our lat/lon
  Future<bool> _resolveStation() async {
    if (_latitude == null || _longitude == null) return false;

    // Round to 4 decimal places (NWS requirement)
    final lat = _latitude!.toStringAsFixed(4);
    final lon = _longitude!.toStringAsFixed(4);

    try {
      final response = await _httpClient.get(
        Uri.parse('https://api.weather.gov/points/$lat,$lon'),
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/geo+json',
        },
      );

      if (response.statusCode != 200) {
        print('NWS points API returned ${response.statusCode}');
        return false;
      }

      final data = json.decode(response.body);
      final properties = data['properties'];

      _observationStationUrl =
          properties['observationStations'] as String?;

      // Extract location name from relativeLocation
      final relLoc = properties['relativeLocation']?['properties'];
      if (relLoc != null) {
        final city = relLoc['city'] ?? '';
        final state = relLoc['state'] ?? '';
        _locationName = '$city, $state';
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('weather_location_name', _locationName);
      }

      return _observationStationUrl != null;
    } catch (e) {
      print('NWS station lookup error: $e');
      return false;
    }
  }

  /// Fetch current weather observation
  Future<void> _fetchWeather() async {
    if (!_enabled) return;

    // Resolve location if needed
    if (_latitude == null || _longitude == null) {
      final ok = await _resolveGpsLocation();
      if (!ok) {
        notifyListeners();
        return;
      }
    }

    // Resolve station if needed
    if (_observationStationUrl == null) {
      final ok = await _resolveStation();
      if (!ok) {
        _error = 'Could not find weather station';
        notifyListeners();
        return;
      }
    }

    try {
      _loading = true;
      // Don't notify for loading — keeps UI smooth

      // Get the first station from the stations list
      final stationsResponse = await _httpClient.get(
        Uri.parse(_observationStationUrl!),
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/geo+json',
        },
      );

      if (stationsResponse.statusCode != 200) {
        _loading = false;
        // Don't clobber existing weather data if we have it — but if this
        // is the first fetch, set an error so the widget shows something.
        if (_currentWeather == null) {
          _error = 'Weather station list unavailable (HTTP ${stationsResponse.statusCode})';
          notifyListeners();
        }
        return;
      }

      final stationsData = json.decode(stationsResponse.body);
      final features = stationsData['features'] as List?;
      if (features == null || features.isEmpty) {
        _loading = false;
        if (_currentWeather == null) {
          _error = 'No weather stations near this location';
          notifyListeners();
        }
        return;
      }

      final stationId =
          features[0]['properties']['stationIdentifier'] as String;

      // Get latest observation
      final obsResponse = await _httpClient.get(
        Uri.parse(
            'https://api.weather.gov/stations/$stationId/observations/latest'),
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/geo+json',
        },
      );

      if (obsResponse.statusCode != 200) {
        _loading = false;
        if (_currentWeather == null) {
          _error = 'Weather observation unavailable (HTTP ${obsResponse.statusCode})';
          notifyListeners();
        }
        return;
      }

      final obsData = json.decode(obsResponse.body);
      final props = obsData['properties'];

      // Parse temperature (NWS returns Celsius)
      double? tempF;
      final tempC = props['temperature']?['value'];
      if (tempC != null) {
        tempF = (tempC as num).toDouble() * 9 / 5 + 32;
      }

      double? feelsLikeF;
      final windChillC = props['windChill']?['value'];
      final heatIndexC = props['heatIndex']?['value'];
      if (heatIndexC != null) {
        feelsLikeF = (heatIndexC as num).toDouble() * 9 / 5 + 32;
      } else if (windChillC != null) {
        feelsLikeF = (windChillC as num).toDouble() * 9 / 5 + 32;
      }

      double? humidity;
      final rh = props['relativeHumidity']?['value'];
      if (rh != null) {
        humidity = (rh as num).toDouble();
      }

      double? windSpeedMph;
      final windKmh = props['windSpeed']?['value'];
      if (windKmh != null) {
        windSpeedMph = (windKmh as num).toDouble() * 0.621371;
      }

      final windDir = props['windDirection']?['value'];
      String? windDirection;
      if (windDir != null) {
        windDirection = _degreesToCardinal((windDir as num).toDouble());
      }

      final textDescription =
          (props['textDescription'] as String?) ?? 'Unknown';

      // Determine day/night from the icon URL (contains /day/ or /night/)
      final iconUrl = (props['icon'] as String?) ?? '';
      final isDaytime = !iconUrl.contains('/night/');

      final emoji = _mapConditionToEmoji(textDescription, isDaytime);

      _currentWeather = WeatherData(
        temperatureF: tempF,
        feelsLikeF: feelsLikeF,
        humidity: humidity,
        windSpeedMph: windSpeedMph,
        windDirection: windDirection,
        description: textDescription,
        emoji: emoji,
        isDaytime: isDaytime,
        locationName: _locationName,
        timestamp: DateTime.now(),
      );

      _error = null;
      _loading = false;
      _consecutiveErrors = 0;

      // Update ambient sounds based on current conditions
      _updateAmbientSounds(textDescription);

      notifyListeners();
    } catch (e) {
      print('Weather fetch error: $e');
      _loading = false;
      _consecutiveErrors++;

      // Exponential backoff: skip next N polls based on error count
      // After 3 errors, start backing off (skip 2, 4, 8... polls)
      if (_consecutiveErrors >= 3) {
        final backoffMinutes = (_observationInterval.inMinutes *
                (1 << (_consecutiveErrors - 3).clamp(0, 4)))
            .clamp(0, _maxBackoffMinutes);
        print(
            'Weather: backing off for $backoffMinutes min after $_consecutiveErrors errors');
      }

      // Keep showing old data if we have it
      if (_currentWeather == null) {
        _error = 'Weather unavailable';
        notifyListeners();
      }
    }
  }

  /// Fetch active weather alerts
  Future<void> _fetchAlerts() async {
    if (!_enabled) return;
    if (_latitude == null || _longitude == null) return;
    if (_alertMode == 'off') return;

    try {
      final lat = _latitude!.toStringAsFixed(4);
      final lon = _longitude!.toStringAsFixed(4);

      final response = await _httpClient.get(
        Uri.parse(
            'https://api.weather.gov/alerts/active?point=$lat,$lon'),
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/geo+json',
        },
      );

      if (response.statusCode != 200) return;

      final data = json.decode(response.body);
      final features = data['features'] as List? ?? [];

      // Prune expired alerts from seen set
      _seenAlertIds.removeWhere((id) {
        return !features.any((f) => f['properties']?['id'] == id);
      });

      for (final feature in features) {
        final props = feature['properties'];
        final id = props['id'] as String? ?? '';
        if (id.isEmpty) continue;

        // Skip if already seen
        if (_seenAlertIds.contains(id)) continue;

        final severity = props['severity'] as String? ?? 'Unknown';

        // Apply severity filter
        if (_alertSeverity == 'severe_only') {
          if (severity != 'Extreme' && severity != 'Severe') continue;
        }

        _seenAlertIds.add(id);

        final alert = WeatherAlert(
          id: id,
          event: props['event'] as String? ?? 'Weather Alert',
          headline: props['headline'] as String? ?? '',
          severity: severity,
          urgency: props['urgency'] as String? ?? 'Unknown',
          onset: props['onset'] != null
              ? DateTime.tryParse(props['onset'] as String)
              : null,
          expires: props['expires'] != null
              ? DateTime.tryParse(props['expires'] as String)
              : null,
          description: props['description'] as String? ?? '',
        );

        // Add to history (newest first, cap at 50)
        _alertHistory.insert(0, alert);
        if (_alertHistory.length > 50) {
          _alertHistory.removeLast();
        }

        // Set as latest for banner display
        _latestAlert = alert;
        notifyListeners();

        // Fire callback for TTS/banner handling
        onNewAlert?.call(alert);
      }
    } catch (e) {
      print('Alert fetch error: $e');
    }
  }

  /// Fire a test alert for testing TTS + banner
  void fireTestAlert() {
    final alert = WeatherAlert(
      id: 'test-${DateTime.now().millisecondsSinceEpoch}',
      event: 'Severe Thunderstorm Warning',
      headline:
          'Severe Thunderstorm Warning issued for Elko County until 9:45 PM. '
          'Large hail and damaging winds expected.',
      severity: 'Severe',
      urgency: 'Immediate',
      onset: DateTime.now(),
      expires: DateTime.now().add(const Duration(hours: 2)),
      description: 'This is a test alert.',
    );

    _alertHistory.insert(0, alert);
    if (_alertHistory.length > 50) {
      _alertHistory.removeLast();
    }

    _latestAlert = alert;
    notifyListeners();
    onNewAlert?.call(alert);
  }

  /// Initialize TTS engine
  Future<void> _initTts() async {
    if (_ttsInitialized) return;
    _tts = FlutterTts();
    await _tts!.setSpeechRate(0.45); // Slightly slow for clarity
    await _tts!.setVolume(1.0);
    await _tts!.setPitch(1.0);

    _tts!.setCompletionHandler(() {
      _onTtsComplete();
    });

    _ttsInitialized = true;
  }

  /// Announce a weather alert via TTS with volume ducking
  Future<void> announceAlert(WeatherAlert alert) async {
    // Check if voice alerts are enabled
    if (_alertMode == 'banner_only' || _alertMode == 'off') return;

    // De-dup: speak each alert ONCE, even across app restarts. NWS alert IDs are
    // stable, so a persisted set of already-spoken IDs stops the same active
    // alert (e.g. a multi-day fire weather watch) from re-announcing every open.
    if (_announcedAlertIds.contains(alert.id)) return;

    // Queue if already announcing
    if (_announcing) {
      _announcementQueue.add(alert);
      return;
    }

    // Mark spoken now (persisted) so it never repeats.
    _announcedAlertIds.add(alert.id);
    _saveAnnouncedAlertIds();

    _announcing = true;

    try {
      await _initTts();

      // Duck music volume if something is playing
      final isPlaying = audioPlayerService?.isPlaying ?? false;
      if (isPlaying) {
        audioPlayerService?.duckVolume(0.25);
      }

      // Play chime based on severity
      try {
        final chimeAsset = alert.isSevere
            ? 'assets/sounds/alert_severe.wav'
            : 'assets/sounds/alert_moderate.wav';

        // Check if asset exists before playing
        try {
          await rootBundle.load(chimeAsset);
          await _chimePlayer.play(ap.AssetSource(chimeAsset.replaceFirst('assets/', '')));
          // Wait for chime to finish
          await Future.delayed(const Duration(milliseconds: 1500));
        } catch (_) {
          // No chime asset yet — skip silently
        }
      } catch (e) {
        print('Chime playback error: $e');
      }

      // Build the announcement text
      final text =
          'National Weather Service ${alert.event}. ${alert.headline}';

      // Speak via TTS
      await _tts!.speak(text);
      // TTS completion handled by setCompletionHandler
    } catch (e) {
      print('TTS announcement error: $e');
      _announcing = false;
      audioPlayerService?.restoreVolume();
    }
  }

  void _onTtsComplete() {
    // Restore volume
    audioPlayerService?.restoreVolume();
    _announcing = false;

    // Process queue
    if (_announcementQueue.isNotEmpty) {
      final next = _announcementQueue.removeAt(0);
      announceAlert(next);
    }
  }

  /// Persist the set of already-spoken alert IDs. Bounded — old alerts expire,
  /// so only the most recent IDs matter; cap at 100 so it can't grow forever.
  void _saveAnnouncedAlertIds() {
    if (_announcedAlertIds.length > 100) {
      _announcedAlertIds =
          _announcedAlertIds.sublist(_announcedAlertIds.length - 100);
    }
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList('weather_announced_alert_ids', _announcedAlertIds);
    });
  }

  /// Map NWS text description to weather emoji
  String _mapConditionToEmoji(String description, bool isDaytime) {
    final desc = description.toLowerCase();

    if (desc.contains('thunder') || desc.contains('storm')) return '\u26C8\uFE0F';
    if (desc.contains('rain') ||
        desc.contains('drizzle') ||
        desc.contains('shower')) return '\uD83C\uDF27\uFE0F';
    if (desc.contains('snow') ||
        desc.contains('blizzard') ||
        desc.contains('sleet') ||
        desc.contains('ice') ||
        desc.contains('freezing')) return '\uD83C\uDF28\uFE0F';
    if (desc.contains('fog') ||
        desc.contains('mist') ||
        desc.contains('haze') ||
        desc.contains('smoke')) return '\uD83C\uDF2B\uFE0F';
    if (desc.contains('wind') || desc.contains('breezy') || desc.contains('gusty')) {
      return '\uD83D\uDCA8';
    }
    if (desc.contains('partly') || desc.contains('mostly sunny') || desc.contains('few clouds')) {
      return isDaytime ? '\u26C5' : '\uD83C\uDF19';
    }
    if (desc.contains('cloud') || desc.contains('overcast')) return '\u2601\uFE0F';
    // Clear / fair / sunny
    return isDaytime ? '\u2600\uFE0F' : '\uD83C\uDF19';
  }

  /// Convert wind degrees to cardinal direction
  String _degreesToCardinal(double degrees) {
    const directions = [
      'N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE',
      'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'
    ];
    final index = ((degrees + 11.25) / 22.5).floor() % 16;
    return directions[index];
  }

  /// Update ambient weather sounds based on current conditions
  void _updateAmbientSounds(String description) {
    if (!_ambientSounds || !_enabled) {
      _stopAmbientSounds();
      return;
    }

    final desc = description.toLowerCase();
    final isRaining = desc.contains('rain') ||
        desc.contains('drizzle') ||
        desc.contains('shower') ||
        desc.contains('thunder');

    if (isRaining && !_ambientPlaying) {
      _startAmbientSounds();
    } else if (!isRaining && _ambientPlaying) {
      _stopAmbientSounds();
    }
  }

  Future<void> _startAmbientSounds() async {
    try {
      await _ambientPlayer.setVolume(0.15);
      await _ambientPlayer.setReleaseMode(ap.ReleaseMode.loop);
      await _ambientPlayer.play(ap.AssetSource('sounds/rain_ambient.wav'));
      _ambientPlaying = true;
    } catch (e) {
      // No ambient asset yet — fail silently
      print('Ambient sound error: $e');
    }
  }

  void _stopAmbientSounds() {
    if (_ambientPlaying) {
      _ambientPlayer.stop();
      _ambientPlaying = false;
    }
  }

  @override
  void dispose() {
    _stopPolling();
    _stopAmbientSounds();
    _httpClient.close();
    _tts?.stop();
    _chimePlayer.dispose();
    _ambientPlayer.dispose();
    super.dispose();
  }
}
