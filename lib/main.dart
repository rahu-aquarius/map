// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:js' as js;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Territory Capture Game',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
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

  // H3 Game State - Track all captured zones
  Set<String> capturedZones = {};
  Map<String, List<LatLng>> zoneBoundaries = {};

  @override
  void initState() {
    super.initState();
    mapController = MapController();
    _requestLocationPermission();
  }

  /// Waits for H3 library to load, then calculates the hexagon
  Future<void> _calculateH3(LatLng location) async {
    try {
      // Wait up to 5 seconds for the H3 library to load
      int attempts = 0;
      const maxAttempts = 50; // 50 * 100ms = 5 seconds max

      while (attempts < maxAttempts) {
        final h3Lib = js.context['h3'];

        if (h3Lib != null) {
          debugPrint('✅ H3 library loaded on attempt ${attempts + 1}');
          _processH3Calculation(h3Lib, location);
          return;
        }

        // Library not loaded yet, wait 100ms and retry
        await Future.delayed(const Duration(milliseconds: 100));
        attempts++;
      }

      debugPrint('❌ ERROR: H3 JS library failed to load after 5 seconds!');
      debugPrint('   Make sure this script is in web/index.html:');
      debugPrint(
        '   <script src=\"https://cdn.jsdelivr.net/npm/h3-js@4.1.0/dist/h3.umd.js\"></script>',
      );
    } catch (e) {
      debugPrint('ERROR in _calculateH3: $e');
    }
  }

  /// Process the H3 calculation once library is confirmed loaded
  /// Adds to the captured zones instead of overwriting
  void _processH3Calculation(dynamic h3Lib, LatLng location) {
    try {
      debugPrint(
        '📍 Converting Lat/Lng (${location.latitude}, ${location.longitude}) to H3 Index...',
      );

      // 1. Convert Lat/Lng to H3 Index at Resolution 10
      final h3Index = h3Lib.callMethod('latLngToCell', [
        location.latitude,
        location.longitude,
        10, // Resolution 10 = ~50m hexagons
      ]);

      debugPrint('✅ H3 Index calculated: $h3Index');

      if (h3Index == null || h3Index.toString().isEmpty) {
        debugPrint('❌ ERROR: H3 Index is null or empty');
        return;
      }

      final h3IndexStr = h3Index.toString();

      // Check if we've already captured this zone
      if (capturedZones.contains(h3IndexStr)) {
        debugPrint('⚠️  Zone $h3IndexStr already captured!');
        return;
      }

      // 2. Get the 6 corners of the hexagon polygon
      final jsBoundary = h3Lib.callMethod('cellToBoundary', [h3Index]);

      if (jsBoundary == null) {
        debugPrint('❌ ERROR: cellToBoundary returned null');
        return;
      }

      final boundaryLength = jsBoundary['length'] as int;
      debugPrint('📐 Hexagon has $boundaryLength vertices');

      final List<LatLng> newBoundary = [];

      // Loop through the JavaScript array of [lat, lng] pairs
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

      // 3. ADD to the captured zones collection (not replace)
      setState(() {
        capturedZones.add(h3IndexStr);
        zoneBoundaries[h3IndexStr] = newBoundary;
      });

      debugPrint(
        '🎨 Zone added to trail! Total zones: ${capturedZones.length}',
      );
    } catch (e) {
      debugPrint('❌ ERROR calculating H3 hexagon: $e');
    }
  }

  /// Handle map tap for dev mode teleportation
  Future<void> _onMapTap(TapPosition tapPosition, LatLng tappedLocation) async {
    debugPrint(
      '🎮 DEV MODE: Tapped at ${tappedLocation.latitude}, ${tappedLocation.longitude}',
    );

    // Update user location to tapped position
    setState(() {
      userLocation = tappedLocation;
    });

    // Calculate and add the hexagon at the new location
    await _calculateH3(tappedLocation);
  }

  Future<void> _requestLocationPermission() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          locationDenied = true;
          isLoading = false;
        });
        return;
      }

      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.best,
        );
        final loc = LatLng(position.latitude, position.longitude);

        setState(() {
          userLocation = loc;
          isLoading = false;
        });

        // Calculate the hexagon for where the user is standing!
        await _calculateH3(loc);
      } else {
        setState(() {
          locationDenied = true;
          isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        locationDenied = true;
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Loading Map...'), centerTitle: true),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (locationDenied) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Territory Capture Game'),
          centerTitle: true,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.location_off, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              const Text(
                'Location permission is required to play.',
                style: TextStyle(fontSize: 18),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _requestLocationPermission,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        // Show the count of captured zones
        title: Text('Territory Captured: ${capturedZones.length} zones'),
        centerTitle: true,
        elevation: 0,
      ),
      body: FlutterMap(
        mapController: mapController,
        options: MapOptions(
          initialCenter: userLocation ?? kathmandu,
          initialZoom: 17.0, // Zoomed in closer so we can see the hexagons
          minZoom: 5.0,
          maxZoom: 18.0,
          // DEV MODE: Tap map to simulate walking and capturing zones
          onTap: _onMapTap,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.app',
          ),

          // Draw all captured hexagons
          if (zoneBoundaries.isNotEmpty)
            PolygonLayer(
              polygons: [
                // Create a polygon for each captured zone
                for (final entry in zoneBoundaries.entries)
                  Polygon(
                    points: entry.value,
                    color: Colors.green.withValues(alpha: 0.3),
                    borderColor: Colors.green,
                    borderStrokeWidth: 2.0,
                  ),
              ],
            ),

          // Draw the User Location Layer
          MarkerLayer(
            markers: [
              if (userLocation != null)
                Marker(
                  point: userLocation!,
                  width: 80,
                  height: 80,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.3),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.blue, width: 2),
                    ),
                    child: const Icon(
                      Icons.my_location,
                      color: Colors.blue,
                      size: 24,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    mapController.dispose();
    super.dispose();
  }
}
