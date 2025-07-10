import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:location/location.dart' as loc;
import 'package:permission_handler/permission_handler.dart' as perm;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

// Background task callback
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    switch (task) {
      case "locationTracking":
        try {
          // Initialize location service
          loc.Location location = loc.Location();
          
          // Check if location service is enabled
          bool serviceEnabled = await location.serviceEnabled();
          if (!serviceEnabled) {
            return Future.value(false);
          }

          // Check permissions
          loc.PermissionStatus permissionGranted = await location.hasPermission();
          if (permissionGranted == loc.PermissionStatus.denied) {
            return Future.value(false);
          }

          // Get current location
          loc.LocationData locationData = await location.getLocation();
          
          // Save to shared preferences
          SharedPreferences prefs = await SharedPreferences.getInstance();
          List<String> existingData = prefs.getStringList('location_history') ?? [];
          
          Map<String, dynamic> newLocationData = {
            'latitude': locationData.latitude,
            'longitude': locationData.longitude,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'accuracy': locationData.accuracy,
          };
          
          existingData.add(jsonEncode(newLocationData));
          
          // Keep only last 1000 entries to prevent excessive storage
          if (existingData.length > 1000) {
            existingData = existingData.sublist(existingData.length - 1000);
          }
          
          await prefs.setStringList('location_history', existingData);
          
          // Update last tracking time
          await prefs.setInt('last_tracking_time', DateTime.now().millisecondsSinceEpoch);
          
          return Future.value(true);
        } catch (e) {
          print('Background location tracking error: $e');
          return Future.value(false);
        }
      default:
        return Future.value(false);
    }
  });
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().initialize(callbackDispatcher, isInDebugMode: true);
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Location Heat Map',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: LocationHeatMapScreen(),
    );
  }
}

class LocationHeatMapScreen extends StatefulWidget {
  @override
  _LocationHeatMapScreenState createState() => _LocationHeatMapScreenState();
}

class _LocationHeatMapScreenState extends State<LocationHeatMapScreen> with WidgetsBindingObserver {
  GoogleMapController? _mapController;
  loc.Location _location = loc.Location();
  List<Map<String, dynamic>> _locationHistory = [];
  Set<Circle> _heatMapCircles = {};
  Timer? _locationTimer;
  bool _isTracking = false;
  LatLng _currentPosition = LatLng(37.7749, -122.4194);
  SharedPreferences? _prefs;
  DateTime? _lastTrackingTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationTimer?.cancel();
    if (_isTracking) {
      _stopBackgroundTracking();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    switch (state) {
      case AppLifecycleState.paused:
        // App is going to background
        if (_isTracking) {
          _startBackgroundTracking();
          _locationTimer?.cancel();
        }
        break;
      case AppLifecycleState.resumed:
        // App is coming to foreground
        if (_isTracking) {
          _stopBackgroundTracking();
          _startForegroundTracking();
        }
        _loadLocationData();
        break;
      case AppLifecycleState.detached:
        // App is being terminated
        if (_isTracking) {
          _startBackgroundTracking();
        }
        break;
      default:
        break;
    }
  }

  Future<void> _initializeApp() async {
    _prefs = await SharedPreferences.getInstance();
    await _initializeLocation();
    await _loadLocationData();
    
    // Check if tracking was enabled before app was closed
    bool wasTracking = _prefs?.getBool('was_tracking') ?? false;
    if (wasTracking) {
      _startLocationTracking();
    }
  }

  Future<void> _initializeLocation() async {
    // Request location permissions
    var status = await perm.Permission.location.request();
    if (status.isGranted) {
      bool serviceEnabled = await _location.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await _location.requestService();
        if (!serviceEnabled) {
          return;
        }
      }

      loc.PermissionStatus permissionGranted = await _location.hasPermission();
      if (permissionGranted == loc.PermissionStatus.denied) {
        permissionGranted = await _location.requestPermission();
        if (permissionGranted != loc.PermissionStatus.granted) {
          return;
        }
      }

      // Get current location
      try {
        loc.LocationData currentLocation = await _location.getLocation();
        setState(() {
          _currentPosition = LatLng(currentLocation.latitude!, currentLocation.longitude!);
        });
      } catch (e) {
        print('Error getting current location: $e');
      }
    }
  }

  Future<void> _loadLocationData() async {
    if (_prefs == null) return;
    
    List<String> savedData = _prefs!.getStringList('location_history') ?? [];
    List<Map<String, dynamic>> locationHistory = [];
    
    for (String dataString in savedData) {
      try {
        Map<String, dynamic> locationData = jsonDecode(dataString);
        locationHistory.add(locationData);
      } catch (e) {
        print('Error parsing location data: $e');
      }
    }
    
    setState(() {
      _locationHistory = locationHistory;
      _updateHeatMap();
    });
    
    // Update last tracking time
    int? lastTime = _prefs!.getInt('last_tracking_time');
    if (lastTime != null) {
      _lastTrackingTime = DateTime.fromMillisecondsSinceEpoch(lastTime);
    }
  }

  Future<void> _saveLocationData() async {
    if (_prefs == null) return;
    
    List<String> dataToSave = _locationHistory.map((data) => jsonEncode(data)).toList();
    await _prefs!.setStringList('location_history', dataToSave);
  }

  void _startLocationTracking() {
    setState(() {
      _isTracking = true;
    });
    
    // Save tracking state
    _prefs?.setBool('was_tracking', true);
    
    _startForegroundTracking();
  }

  void _startForegroundTracking() {
    _locationTimer = Timer.periodic(Duration(seconds: 30), (timer) async {
      await _recordCurrentLocation();
    });
  }

  Future<void> _recordCurrentLocation() async {
    try {
      loc.LocationData locationData = await _location.getLocation();
      
      Map<String, dynamic> newLocationData = {
        'latitude': locationData.latitude,
        'longitude': locationData.longitude,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'accuracy': locationData.accuracy,
      };
      
      setState(() {
        _locationHistory.add(newLocationData);
        _updateHeatMap();
      });
      
      await _saveLocationData();
    } catch (e) {
      print('Error recording location: $e');
    }
  }

  void _startBackgroundTracking() {
    // Register periodic background task
    Workmanager().registerPeriodicTask(
      "locationTrackingTask",
      "locationTracking",
      frequency: Duration(minutes: 15), // Minimum frequency for iOS/Android
      constraints: Constraints(
        networkType: NetworkType.notRequired,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
        requiresStorageNotLow: false,
      ),
    );
  }

  void _stopBackgroundTracking() {
    Workmanager().cancelByUniqueName("locationTrackingTask");
  }

  void _stopLocationTracking() {
    setState(() {
      _isTracking = false;
    });
    
    // Save tracking state
    _prefs?.setBool('was_tracking', false);
    
    _locationTimer?.cancel();
    _stopBackgroundTracking();
  }

  void _updateHeatMap() {
    Map<String, int> locationCounts = {};
    Set<Circle> circles = {};

    // Count visits to each location (rounded to reduce precision and group nearby locations)
    for (Map<String, dynamic> location in _locationHistory) {
      double lat = location['latitude'];
      double lng = location['longitude'];
      
      // Round to 3 decimal places (~111m precision) to group nearby GPS points
      String key = '${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)}';
      locationCounts[key] = (locationCounts[key] ?? 0) + 1;
    }

    // Create heat map circles
    locationCounts.forEach((key, count) {
      List<String> coords = key.split(',');
      double lat = double.parse(coords[0]);
      double lng = double.parse(coords[1]);

      // Calculate intensity based on visit count (slower progression)
      double intensity = math.min(count / 25.0, 1.0); // Normalize to 0-1 (requires more visits)
      Color circleColor = _getHeatMapColor(intensity);

      circles.add(Circle(
        circleId: CircleId(key),
        center: LatLng(lat, lng),
        radius: 100,
        fillColor: circleColor.withOpacity(0.3),
        strokeColor: circleColor,
        strokeWidth: 2,
      ));
    });

    setState(() {
      _heatMapCircles = circles;
    });
  }

  Color _getHeatMapColor(double intensity) {
    // More conservative color thresholds - requires more visits to change colors
    if (intensity < 0.15) {
      return Colors.blue;
    } else if (intensity < 0.35) {
      return Colors.green;
    } else if (intensity < 0.65) {
      return Colors.yellow;
    } else {
      return Colors.red;
    }
  }

  void _clearHeatMap() {
    setState(() {
      _locationHistory.clear();
      _heatMapCircles.clear();
      _lastTrackingTime = null;
    });
    
    // Clear saved data
    _prefs?.remove('location_history');
    _prefs?.remove('last_tracking_time');
  }

  void _centerOnCurrentLocation() async {
    try {
      loc.LocationData currentLocation = await _location.getLocation();
      _mapController?.animateCamera(
        CameraUpdate.newLatLng(
          LatLng(currentLocation.latitude!, currentLocation.longitude!),
        ),
      );
    } catch (e) {
      print('Error centering on current location: $e');
    }
  }

  String _getTrackingStatus() {
    if (!_isTracking) return 'Stopped';
    if (_lastTrackingTime != null) {
      Duration difference = DateTime.now().difference(_lastTrackingTime!);
      if (difference.inMinutes < 5) {
        return 'Active';
      } else {
        return 'Background';
      }
    }
    return 'Active';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Location Heat Map'),
        backgroundColor: const Color.fromARGB(255, 255, 255, 255),
      ),
      body: Column(
        children: [
          // Stats Panel
          Container(
            color: Colors.white,
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildStatCard('Locations Tracked', _locationHistory.length.toString()),
                    _buildStatCard('Heat Points', _heatMapCircles.length.toString()),
                    _buildStatCard('Status', _getTrackingStatus()),
                  ],
                ),
                if (_lastTrackingTime != null)
                  Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Last update: ${_formatTime(_lastTrackingTime!)}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ),
              ],
            ),
          ),
          // Map
          Expanded(
            child: GoogleMap(
              onMapCreated: (GoogleMapController controller) {
                _mapController = controller;
              },
              initialCameraPosition: CameraPosition(
                target: _currentPosition,
                zoom: 15,
              ),
              circles: _heatMapCircles,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
            ),
          ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(width: 25),
          ElevatedButton(
            onPressed: () {},
            child: SizedBox(
              width: 145,
              height: 59,
              child: Row(
                children: [
                  IconButton(
                    onPressed: _isTracking ? _stopLocationTracking : _startLocationTracking,
                    icon: Icon(
                      _isTracking ? Icons.stop_rounded : Icons.play_arrow_rounded,
                      color: Colors.black,
                      size: 30,
                    ),
                  ),
                  IconButton(
                    onPressed: _centerOnCurrentLocation,
                    icon: Icon(
                      Icons.my_location,
                      size: 28,
                      color: Colors.black,
                    ),
                  ),
                  IconButton(
                    onPressed: () => _showLegend(context),
                    icon: Icon(
                      Icons.info_rounded,
                      color: Colors.black,
                      size: 29,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(width: 15),
          FloatingActionButton(
            onPressed: _clearHeatMap,
            child: Icon(Icons.clear_rounded, color: Colors.red, size: 28),
            backgroundColor: Colors.red[100],
            heroTag: "clear",
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String title, String value) {
    return Card(
      color: Colors.black,
      child: Padding(
        padding: EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(fontSize: 16, color: const Color.fromARGB(255, 204, 204, 204)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    Duration diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) {
      return 'Just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else {
      return '${diff.inDays}d ago';
    }
  }

  void _showLegend(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Heat Map Legend'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Heat map colors represent visit frequency:'),
              SizedBox(height: 10),
              _buildLegendItem(Colors.blue, 'Low activity (1-4 visits)'),
              _buildLegendItem(Colors.green, 'Medium activity (5-9 visits)'),
              _buildLegendItem(Colors.yellow, 'High activity (10-16 visits)'),
              _buildLegendItem(Colors.red, 'Very high activity (17+ visits)'),
              SizedBox(height: 10),
              Text('• Data is saved automatically'),
              Text('• Tracks in background when app is closed'),
              Text('• Location checked every 30 seconds (foreground)'),
              Text('• Background updates every 15 minutes'),
              Text('• Keeps last 1000 location points'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Got it'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLegendItem(Color color, String description) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: 8),
          Expanded(child: Text(description, style: TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}