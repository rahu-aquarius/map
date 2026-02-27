// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:js' as js;
import 'dart:ui' as ui;
import 'dart:math' show Random;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Territory Capture Game',
      theme: ThemeData.dark(useMaterial3: true),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  static const LatLng kathmandu = LatLng(27.7172, 85.3240);
  late MapController mapController;

  LatLng? userLocation;
  bool locationDenied = false;
  bool isLoading = true;

  // ============================================
  // H3 GAME STATE - Track all captured zones
  // ============================================
  Set<String> capturedZones = {};
  Map<String, List<LatLng>> zoneBoundaries = {};

  // ============================================
  // GAMIFICATION - Scoring System
  // ============================================
  int userScore = 0;
  static const int pointsPerZone = 100;

  // ============================================
  // PERSISTENCE - Shared Preferences
  // ============================================
  late SharedPreferences _prefs;
  static const String _capturedZonesKey = 'capturedZones';
  static const String _userScoreKey = 'userScore';

  // ============================================
  // RPG LEVELING SYSTEM
  // ============================================
  /// Calculate player level: 0-4 zones = Lvl 1, 5-9 zones = Lvl 2, etc.
  int get playerLevel => (capturedZones.length ~/ 5) + 1;

  /// Calculate progress to next level (0.0 to 1.0)
  /// Example: 2 zones out of 5 = 0.4 progress
  double get progressToNextLevel {
    final zonesInCurrentLevel = capturedZones.length % 5;
    return zonesInCurrentLevel / 5.0;
  }

  // ============================================
  // LOOT SYSTEM - Neon Data Caches
  // ============================================
  List<LatLng> activeCaches = []; // Stores active loot cache locations
  static const int bonusPointsPerCache = 500; // Bonus for capturing a cache

  @override
  void initState() {
    super.initState();
    mapController = MapController();
    _initializeAppStrict();
  }

  /// ============================================================
  /// BULLETPROOF INITIALIZATION - Strict Order to Fix Race Condition
  /// ============================================================
  /// This follows a STRICT initialization sequence:
  /// 1. Set loading state
  /// 2. Load SharedPreferences
  /// 3. Load saved zones and score from storage
  /// 4. Wait for H3 JS library to be ready (retry loop 5 seconds)
  /// 5. Calculate boundaries for ALL saved zones
  /// 6. Request location permission and get initial GPS position
  /// 7. ONLY AFTER ALL ABOVE, set isLoading = false so map renders
  /// ============================================================
  Future<void> _initializeAppStrict() async {
    try {
      debugPrint('🚀 APP INITIALIZATION STARTING...');

      // STEP 1: Set loading state
      setState(() {
        isLoading = true;
      });

      // STEP 2: Load SharedPreferences
      debugPrint('⏳ [STEP 2] Loading SharedPreferences...');
      _prefs = await SharedPreferences.getInstance();
      debugPrint('✅ [STEP 2] SharedPreferences loaded');

      // STEP 3: Load saved zones and score from storage
      debugPrint('⏳ [STEP 3] Loading saved data from storage...');
      await _loadSavedDataFromStorage();
      debugPrint(
        '✅ [STEP 3] Loaded ${capturedZones.length} zones, Score: $userScore',
      );

      // STEP 4 & 5: Wait for H3 library and calculate boundaries
      debugPrint('⏳ [STEP 4-5] Waiting for H3 JS library...');
      await _waitForH3LibraryAndCalculateBoundaries();
      debugPrint('✅ [STEP 4-5] H3 library ready, boundaries calculated');

      // STEP 6: Request location permission and get initial position
      debugPrint('⏳ [STEP 6] Requesting location permission...');
      await _requestLocationPermissionStrict();
      debugPrint('✅ [STEP 6] Location permission complete');

      // STEP 6B: Spawn initial loot caches if user location is available
      if (userLocation != null && activeCaches.isEmpty) {
        debugPrint('⏳ [STEP 6B] Spawning initial loot caches...');
        _spawnCaches(userLocation!);
        debugPrint('✅ [STEP 6B] ${activeCaches.length} loot caches spawned');
      }

      // STEP 7: ONLY NOW set isLoading = false so the map renders
      // This ensures all zones are already calculated and in memory
      debugPrint('⏳ [STEP 7] Setting isLoading = false...');
      setState(() {
        isLoading = false;
      });
      debugPrint('🎉 [STEP 7] Map is now ready to render with all zones!');

      debugPrint('✅ APP INITIALIZATION COMPLETE');
    } catch (e) {
      debugPrint('❌ CRITICAL ERROR during app initialization: $e');
      setState(() {
        isLoading = false;
      });
    }
  }

  /// Load saved zones and user score from SharedPreferences storage
  Future<void> _loadSavedDataFromStorage() async {
    try {
      final savedZones = _prefs.getStringList(_capturedZonesKey) ?? [];
      final savedScore = _prefs.getInt(_userScoreKey) ?? 0;

      if (savedZones.isEmpty) {
        debugPrint('📦 No saved zones found in storage (fresh start)');
        userScore = 0;
        return;
      }

      debugPrint('📦 Found ${savedZones.length} saved zones in storage');
      debugPrint('💰 Loaded saved score: $savedScore points');

      // Add zones to the Set (without calculating boundaries yet)
      capturedZones.addAll(savedZones);
      userScore = savedScore;
    } catch (e) {
      debugPrint('❌ Error loading saved data: $e');
    }
  }

  /// Wait for H3 JS library to be ready, then calculate boundaries for all saved zones
  /// This is called BEFORE the map renders
  Future<void> _waitForH3LibraryAndCalculateBoundaries() async {
    if (capturedZones.isEmpty) {
      debugPrint('📦 No zones to restore, skipping H3 calculation');
      return;
    }

    debugPrint('⏳ Waiting for H3 JS library to load...');

    // Retry loop: wait up to 5 seconds for H3 library
    int attempts = 0;
    dynamic h3Lib;
    const maxAttempts = 50; // 50 * 100ms = 5 seconds

    while (attempts < maxAttempts) {
      h3Lib = js.context['h3'];
      if (h3Lib != null) {
        debugPrint('✅ JS Library Ready (attempt ${attempts + 1})');
        break;
      }
      await Future.delayed(const Duration(milliseconds: 100));
      attempts++;
    }

    if (h3Lib == null) {
      debugPrint(
        '❌ FATAL: H3 library failed to load after ${attempts * 100}ms',
      );
      debugPrint('   Make sure web/index.html has:');
      debugPrint(
        '   <script src="https://cdn.jsdelivr.net/npm/h3-js@4.1.0/dist/h3.umd.js"></script>',
      );
      return;
    }

    // Calculate boundaries for ALL saved zones BEFORE map renders
    debugPrint(
      '📐 Calculating boundaries for ${capturedZones.length} zones...',
    );
    for (final h3Index in capturedZones) {
      _calculateZoneBoundary(h3Lib, h3Index);
    }
    debugPrint('✅ All boundaries calculated');
  }

  /// Calculate the boundary for a single zone from its H3 index
  void _calculateZoneBoundary(dynamic h3Lib, String h3Index) {
    try {
      if (zoneBoundaries.containsKey(h3Index)) {
        return; // Already calculated
      }

      final jsBoundary = h3Lib.callMethod('cellToBoundary', [h3Index]);

      if (jsBoundary == null) {
        debugPrint('⚠️  cellToBoundary returned null for: $h3Index');
        return;
      }

      final boundaryLength = jsBoundary['length'] as int;
      final List<LatLng> newBoundary = [];

      for (int i = 0; i < boundaryLength; i++) {
        final coord = jsBoundary[i];
        final lat = (coord[0] as num).toDouble();
        final lng = (coord[1] as num).toDouble();
        newBoundary.add(LatLng(lat, lng));
      }

      zoneBoundaries[h3Index] = newBoundary;
      debugPrint('✅ Boundary calculated for zone: $h3Index');
    } catch (e) {
      debugPrint('❌ Error calculating boundary for $h3Index: $e');
    }
  }

  /// Request location permission strictly
  Future<void> _requestLocationPermissionStrict() async {
    try {
      debugPrint('🔐 Checking location permission status...');
      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        debugPrint('📍 Permission denied, requesting from user...');
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        debugPrint('❌ Location permission permanently denied');
        setState(() {
          locationDenied = true;
        });
        return;
      }

      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        debugPrint('✅ Location permission granted');

        try {
          debugPrint('⏳ Fetching initial GPS position...');
          final position = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.best,
          );
          final loc = LatLng(position.latitude, position.longitude);

          debugPrint(
            '📍 Initial GPS position: ${position.latitude}, ${position.longitude}',
          );

          setState(() {
            userLocation = loc;
          });

          // Capture initial hexagon if not already captured
          await _calculateH3(loc);

          // Start live GPS tracking
          _startGPSTracking();
        } catch (e) {
          debugPrint('⚠️  Could not get initial position: $e');
          debugPrint('🗺️  Using default Kathmandu location');
          setState(() {
            userLocation = kathmandu;
          });
          _startGPSTracking();
        }
      } else {
        debugPrint('⚠️  Location permission not granted (status: $permission)');
        setState(() {
          locationDenied = true;
        });
      }
    } catch (e) {
      debugPrint('❌ Error requesting location permission: $e');
      setState(() {
        locationDenied = true;
      });
    }
  }

  /// Wait for H3 library, then calculate and add a new hexagon
  Future<void> _calculateH3(LatLng location) async {
    try {
      // Wait up to 5 seconds for H3 library
      int attempts = 0;
      const maxAttempts = 50;

      while (attempts < maxAttempts) {
        final h3Lib = js.context['h3'];

        if (h3Lib != null) {
          debugPrint('✅ H3 library loaded on attempt ${attempts + 1}');
          _processH3Calculation(h3Lib, location);
          return;
        }

        await Future.delayed(const Duration(milliseconds: 100));
        attempts++;
      }

      debugPrint('❌ ERROR: H3 JS library failed to load after 5 seconds!');
    } catch (e) {
      debugPrint('❌ Error in _calculateH3: $e');
    }
  }

  /// Process H3 calculation: convert location to hexagon and add to map
  void _processH3Calculation(dynamic h3Lib, LatLng location) {
    try {
      debugPrint(
        '📍 Converting Lat/Lng (${location.latitude}, ${location.longitude}) to H3 Index...',
      );

      // Convert Lat/Lng to H3 Index at Resolution 10 (~50m hexagons)
      final h3Index = h3Lib.callMethod('latLngToCell', [
        location.latitude,
        location.longitude,
        10,
      ]);

      debugPrint('✅ H3 Index calculated: $h3Index');

      if (h3Index == null || h3Index.toString().isEmpty) {
        debugPrint('❌ ERROR: H3 Index is null or empty');
        return;
      }

      final h3IndexStr = h3Index.toString();

      // ============================================
      // LOOT CAPTURE Check (before zone check)
      // ============================================
      // Check if player stepped on any active caches
      for (int i = 0; i < activeCaches.length; i++) {
        final cache = activeCaches[i];
        final cacheH3Index = h3Lib.callMethod('latLngToCell', [
          cache.latitude,
          cache.longitude,
          10,
        ]);

        if (cacheH3Index.toString() == h3IndexStr) {
          debugPrint(
            '💎 CACHE CAPTURED at: ${cache.latitude}, ${cache.longitude}',
          );
          // Remove captured cache
          setState(() {
            activeCaches.removeAt(i);
            userScore += bonusPointsPerCache;
          });
          // Save updated score
          _saveCapturedZonesAndScore();
          // Show golden notification
          _showCacheCapturNotification();
          debugPrint('💰 Bonus points added! Score: $userScore');

          // Replenish caches if all captured
          if (activeCaches.isEmpty) {
            debugPrint('🎯 All caches captured! Spawning new ones...');
            _spawnCaches(location);
          }
          return; // Don't process zone capture on cache tile
        }
      }

      // Check if we've already captured this zone
      if (capturedZones.contains(h3IndexStr)) {
        debugPrint('⚠️  Zone $h3IndexStr already captured!');
        return;
      }

      // Get the 6 corners of the hexagon polygon
      final jsBoundary = h3Lib.callMethod('cellToBoundary', [h3Index]);

      if (jsBoundary == null) {
        debugPrint('❌ ERROR: cellToBoundary returned null');
        return;
      }

      final boundaryLength = jsBoundary['length'] as int;
      debugPrint('📐 Hexagon has $boundaryLength vertices');

      final List<LatLng> newBoundary = [];

      for (int i = 0; i < boundaryLength; i++) {
        final coord = jsBoundary[i];
        final lat = (coord[0] as num).toDouble();
        final lng = (coord[1] as num).toDouble();
        newBoundary.add(LatLng(lat, lng));
        debugPrint('   Vertex $i: Lat=$lat, Lng=$lng');
      }

      debugPrint(
        '✅ Successfully created hexagon with ${newBoundary.length} points',
      );

      // Check if this will trigger a level up BEFORE adding the zone
      final currentLevel = playerLevel;

      // Add to captured zones and calculate boundaries
      setState(() {
        capturedZones.add(h3IndexStr);
        zoneBoundaries[h3IndexStr] = newBoundary;
        // GAMIFICATION: Add points for new zone
        userScore += pointsPerZone;
      });

      // Save to local storage
      _saveCapturedZonesAndScore();

      // Show visual feedback - SnackBar notification
      _showZoneCapturedNotification();

      // Check if we leveled up (capturedZones.length now has the new zone)
      final newLevel = playerLevel;
      if (newLevel > currentLevel) {
        // Trigger level-up celebration
        _showLevelUpCelebration(newLevel);
      }

      debugPrint(
        '🎨 Zone added to trail! Total zones: ${capturedZones.length}',
      );
      debugPrint('💰 Score increased by $pointsPerZone! Total: $userScore');
    } catch (e) {
      debugPrint('❌ ERROR calculating H3 hexagon: $e');
    }
  }

  /// Save captured zones and score to SharedPreferences
  Future<void> _saveCapturedZonesAndScore() async {
    try {
      await _prefs.setStringList(_capturedZonesKey, capturedZones.toList());
      await _prefs.setInt(_userScoreKey, userScore);
      debugPrint(
        '💾 Saved ${capturedZones.length} zones and score ($userScore points) to storage',
      );
    } catch (e) {
      debugPrint('❌ Error saving data: $e');
    }
  }

  /// Show a cyberpunk-themed SnackBar notification when zone is captured
  void _showZoneCapturedNotification() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle, color: Color(0xFF00FF41), size: 20),
            SizedBox(width: 12),
            Text(
              'ZONE SECURED! +100 SCORE',
              style: TextStyle(
                color: Color(0xFF00FF41),
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
        backgroundColor: Colors.black.withValues(alpha: 0.85),
        duration: const Duration(milliseconds: 2000),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xFF00FF41), width: 1.5),
        ),
        margin: const EdgeInsets.all(16),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Show a flashy cyberpunk-terminal style level-up celebration dialog
  void _showLevelUpCelebration(int newLevel) {
    debugPrint('🎉 LEVEL UP! New level: $newLevel');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.9),
                border: Border.all(
                  color: const Color(0xFFFF006E), // Neon magenta
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFF006E).withValues(alpha: 0.6),
                    blurRadius: 24,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Flashing title
                  const Text(
                    'SYSTEM UPGRADE',
                    style: TextStyle(
                      color: Color(0xFFFF006E),
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Level display
                  Text(
                    'LEVEL $newLevel REACHED!',
                    style: const TextStyle(
                      color: Color(0xFF00D9FF),
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.0,
                      fontFamily: 'Courier',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${newLevel * 5} ZONES CAPTURED',
                    style: const TextStyle(
                      color: Color(0xFF00FF41),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 32),
                  // Acknowledge button
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF006E),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'ACKNOWLEDGE',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Spawn 3 random loot caches within 300-500 meters of center point
  void _spawnCaches(LatLng center) {
    try {
      final random = Random();
      activeCaches.clear();

      // Generate 3 random cache locations
      // 1 degree latitude ≈ 111 km, so:
      // 300m ≈ 0.0027 degrees, 500m ≈ 0.0045 degrees
      for (int i = 0; i < 3; i++) {
        // Random offset between 0.0027 and 0.005 degrees (~300-550m)
        final latOffset = 0.0027 + (random.nextDouble() * 0.0023);
        final lngOffset = 0.0027 + (random.nextDouble() * 0.0023);

        // Randomly choose direction (positive or negative)
        final latSign = random.nextBool() ? 1 : -1;
        final lngSign = random.nextBool() ? 1 : -1;

        final cacheLat = center.latitude + (latOffset * latSign);
        final cacheLng = center.longitude + (lngOffset * lngSign);

        activeCaches.add(LatLng(cacheLat, cacheLng));
        debugPrint('💾 Loot Cache $i spawned at: $cacheLat, $cacheLng');
      }

      setState(() {});
      debugPrint('✨ Spawned ${activeCaches.length} neon data caches');
    } catch (e) {
      debugPrint('❌ Error spawning caches: $e');
    }
  }

  /// Show SnackBar when a loot cache is captured
  void _showCacheCapturNotification() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.diamond, color: Color(0xFFFFD700), size: 20),
            SizedBox(width: 12),
            Text(
              'NEON CACHE SECURED! +500 RARE BONUS',
              style: TextStyle(
                color: Color(0xFFFFD700),
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
        backgroundColor: Colors.black.withValues(alpha: 0.85),
        duration: const Duration(milliseconds: 3000),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xFFFFD700), width: 2),
        ),
        margin: const EdgeInsets.all(16),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Animate the map camera to center on user location
  void _centerOnUser() {
    if (userLocation != null) {
      mapController.move(userLocation!, 17.0);
      debugPrint('🎯 Centered map on user location');
    }
  }

  /// Handle map tap for dev mode teleportation
  Future<void> _onMapTap(TapPosition tapPosition, LatLng tappedLocation) async {
    debugPrint(
      '🎮 DEV MODE: Tapped at ${tappedLocation.latitude}, ${tappedLocation.longitude}',
    );

    setState(() {
      userLocation = tappedLocation;
    });

    await _calculateH3(tappedLocation);
  }

  /// Start listening to GPS position stream for live tracking
  Future<void> _startGPSTracking() async {
    try {
      debugPrint('🛰️  Starting live GPS tracking with 7m distance filter...');

      const LocationSettings locationSettings = LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 7,
        timeLimit: Duration(seconds: 10),
      );

      final positionStream = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      );

      positionStream.listen(
        (Position position) {
          final newLocation = LatLng(position.latitude, position.longitude);

          debugPrint(
            '📍 GPS Update: ${position.latitude}, ${position.longitude}',
          );

          setState(() {
            userLocation = newLocation;
          });

          _calculateH3(newLocation);
        },
        onError: (dynamic error) {
          debugPrint('❌ GPS Stream Error: $error');
        },
      );
    } catch (e) {
      debugPrint('❌ Error starting GPS tracking: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(
                color: Color(0xFF00D9FF), // Neon cyan
              ),
              const SizedBox(height: 24),
              const Text(
                'INITIALIZING...',
                style: TextStyle(
                  color: Color(0xFF00D9FF),
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2.0,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (locationDenied) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.location_off,
                size: 64,
                color: Color(0xFF00D9FF),
              ),
              const SizedBox(height: 16),
              const Text(
                'Location permission required',
                style: TextStyle(color: Color(0xFF00D9FF), fontSize: 18),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _requestLocationPermissionStrict,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00D9FF),
                ),
                child: const Text(
                  'ENABLE LOCATION',
                  style: TextStyle(color: Colors.black),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          // ============================================
          // MAP LAYER - Dark CartoDB tiles with neon hexagons
          // ============================================
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: userLocation ?? kathmandu,
              initialZoom: 17.0,
              minZoom: 5.0,
              maxZoom: 18.0,
              onTap: _onMapTap,
            ),
            children: [
              // Dark CartoDB tiles
              TileLayer(
                urlTemplate:
                    'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.example.app',
              ),

              // Neon glow hexagons
              if (zoneBoundaries.isNotEmpty)
                PolygonLayer(
                  polygons: [
                    for (final entry in zoneBoundaries.entries)
                      Polygon(
                        points: entry.value,
                        color: const Color(0xFF00D9FF).withValues(alpha: 0.2),
                        borderColor: const Color(0xFF00D9FF),
                        borderStrokeWidth: 3.0,
                      ),
                  ],
                ),

              // Neon data cache markers - Glowing yellow loot
              if (activeCaches.isNotEmpty)
                MarkerLayer(
                  markers: [
                    for (final cache in activeCaches)
                      Marker(
                        point: cache,
                        width: 60,
                        height: 60,
                        child: Center(
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Outer glowing ring (semi-transparent)
                              Container(
                                width: 60,
                                height: 60,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: const Color(
                                      0xFFFFD700,
                                    ).withValues(alpha: 0.6),
                                    width: 2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(
                                        0xFFFFD700,
                                      ).withValues(alpha: 0.5),
                                      blurRadius: 16,
                                      spreadRadius: 3,
                                    ),
                                  ],
                                ),
                              ),
                              // Inner golden diamond icon
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0xFFFFD700),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(
                                        0xFFFFD700,
                                      ).withValues(alpha: 0.9),
                                      blurRadius: 20,
                                      spreadRadius: 4,
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.diamond,
                                  color: Colors.black87,
                                  size: 22,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),

              // User location marker - Cyberpunk player avatar
              MarkerLayer(
                markers: [
                  if (userLocation != null)
                    Marker(
                      point: userLocation!,
                      width: 80,
                      height: 80,
                      child: Center(
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Pulsing neon ring (semi-transparent outer glow)
                            Container(
                              width: 70,
                              height: 70,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: const Color(
                                    0xFFFF006E,
                                  ).withValues(alpha: 0.5),
                                  width: 2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(
                                      0xFFFF006E,
                                    ).withValues(alpha: 0.4),
                                    blurRadius: 12,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                            ),
                            // Inner neon pink/magenta player dot
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(0xFFFF006E),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(
                                      0xFFFF006E,
                                    ).withValues(alpha: 0.8),
                                    blurRadius: 16,
                                    spreadRadius: 3,
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.person,
                                color: Colors.black,
                                size: 20,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),

          // ============================================
          // HUD LAYER - Cyberpunk heads-up display
          // ============================================
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      border: Border.all(
                        color: const Color(0xFF00D9FF),
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Top row: Score, Zones, Level
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Score display
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'SCORE',
                                  style: TextStyle(
                                    color: Color(0xFF00FF41),
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.5,
                                  ),
                                ),
                                Text(
                                  userScore.toString().padLeft(5, '0'),
                                  style: const TextStyle(
                                    color: Color(0xFF00FF41),
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'Courier',
                                    letterSpacing: 1.0,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(width: 32),
                            // Zones display
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'ZONES',
                                  style: TextStyle(
                                    color: Color(0xFF00D9FF),
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.5,
                                  ),
                                ),
                                Text(
                                  capturedZones.length.toString().padLeft(
                                    3,
                                    '0',
                                  ),
                                  style: const TextStyle(
                                    color: Color(0xFF00D9FF),
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'Courier',
                                    letterSpacing: 1.0,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(width: 32),
                            // Level display
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'LVL',
                                  style: TextStyle(
                                    color: Color(0xFFFF006E),
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.5,
                                  ),
                                ),
                                Text(
                                  playerLevel.toString().padLeft(2, '0'),
                                  style: const TextStyle(
                                    color: Color(0xFFFF006E),
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'Courier',
                                    letterSpacing: 1.0,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        // Progress bar row
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'NEXT LEVEL',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.0,
                              ),
                            ),
                            const SizedBox(height: 6),
                            SizedBox(
                              width: 220,
                              height: 8,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: progressToNextLevel,
                                  backgroundColor: Colors.grey.shade800,
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                        Color(0xFFFF006E), // Neon magenta
                                      ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      // ============================================
      // "CENTER ON ME" FAB - Camera Control
      // ============================================
      floatingActionButton: userLocation != null
          ? FloatingActionButton(
              onPressed: _centerOnUser,
              backgroundColor: Colors.black.withValues(alpha: 0.7),
              materialTapTargetSize: MaterialTapTargetSize.padded,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF00D9FF), width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF00D9FF).withValues(alpha: 0.6),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.my_location,
                  color: Color(0xFF00D9FF),
                  size: 24,
                ),
              ),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  @override
  void dispose() {
    mapController.dispose();
    super.dispose();
  }
}
