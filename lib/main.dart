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
          
          // Configure location settings for background
          await location.changeSettings(
            accuracy: loc.LocationAccuracy.balanced,
            interval: 300000, // 5 minutes
            distanceFilter: 10, // Only update if moved 10 meters
          );
          
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
            'source': 'background',
          };
          
          existingData.add(jsonEncode(newLocationData));
          
          // Keep only last 2000 entries for more history
          if (existingData.length > 2000) {
            existingData = existingData.sublist(existingData.length - 2000);
          }
          
          await prefs.setStringList('location_history', existingData);
          
          // Update last tracking time
          await prefs.setInt('last_tracking_time', DateTime.now().millisecondsSinceEpoch);
          
          // Track consecutive successful background updates
          int consecutiveUpdates = prefs.getInt('consecutive_bg_updates') ?? 0;
          await prefs.setInt('consecutive_bg_updates', consecutiveUpdates + 1);
          
          return Future.value(true);
        } catch (e) {
          print('Background location tracking error: $e');
          // Reset consecutive updates on error
          SharedPreferences prefs = await SharedPreferences.getInstance();
          await prefs.setInt('consecutive_bg_updates', 0);
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
      title: 'Location Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: 'SF Pro Display',
        scaffoldBackgroundColor: Color(0xFFFBFBFB),
        colorScheme: ColorScheme.fromSeed(
          seedColor: Color(0xFF6366F1),
          brightness: Brightness.light,
          surface: Colors.white,
          onSurface: Color(0xFF1F2937),
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Color(0xFFFBFBFB),
          elevation: 0,
          foregroundColor: Color(0xFF1F2937),
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Color(0xFF1F2937),
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
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
  StreamSubscription<loc.LocationData>? _locationSubscription;

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
    _locationSubscription?.cancel();
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
        print('App paused - continuing location tracking in background');
        _startBackgroundTracking();
        break;
      case AppLifecycleState.resumed:
        print('App resumed - refreshing data');
        _loadLocationData();
        break;
      case AppLifecycleState.inactive:
        print('App inactive - maintaining location tracking');
        break;
      case AppLifecycleState.detached:
        print('App detached - starting background tracking');
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
    // Request all necessary permissions including background location
    var locationStatus = await perm.Permission.location.request();
    var locationAlwaysStatus = await perm.Permission.locationAlways.request();
    
    // Also request notification permission for foreground service
    await perm.Permission.notification.request();
    
    if (locationStatus.isGranted || locationAlwaysStatus.isGranted) {
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

      // Configure location settings for continuous tracking
      await _location.changeSettings(
        accuracy: loc.LocationAccuracy.balanced,
        interval: 30000, // 30 seconds 
        distanceFilter: 10, // Update if moved 10 meters
      );

      // Enable background mode - THIS IS KEY!
      await _location.enableBackgroundMode(enable: true);

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
    
    // Show tracking notification to user
    _showTrackingInfo();
  }

  void _startForegroundTracking() {
    // Use continuous location stream - this keeps running even when screen is off
    _locationSubscription = _location.onLocationChanged.listen((loc.LocationData locationData) {
      if (_isTracking) {
        _recordLocationData(locationData, 'continuous');
      }
    });
    
    // Also add a backup timer for extra reliability
    _locationTimer = Timer.periodic(Duration(seconds: 60), (timer) async {
      if (_isTracking) {
        try {
          loc.LocationData locationData = await _location.getLocation();
          _recordLocationData(locationData, 'timer_backup');
        } catch (e) {
          print('Backup location fetch error: $e');
        }
      }
    });
  }

  void _stopForegroundTracking() {
    _locationSubscription?.cancel();
    _locationTimer?.cancel();
  }

  Future<void> _recordLocationData(loc.LocationData locationData, String source) async {
    // Filter out inaccurate readings
    if (locationData.accuracy != null && locationData.accuracy! > 50) {
      return; // Skip if accuracy is worse than 50 meters
    }

    Map<String, dynamic> newLocationData = {
      'latitude': locationData.latitude,
      'longitude': locationData.longitude,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'accuracy': locationData.accuracy,
      'source': source,
    };
    
    // Check if location is significantly different from last recorded
    if (_locationHistory.isNotEmpty) {
      var lastLocation = _locationHistory.last;
      double distance = _calculateDistance(
        lastLocation['latitude'], 
        lastLocation['longitude'],
        locationData.latitude!, 
        locationData.longitude!
      );
      
      // Only record if moved more than 10 meters or it's been more than 2 minutes
      num timeDiff = DateTime.now().millisecondsSinceEpoch - lastLocation['timestamp'];
      if (distance < 10 && timeDiff < 120000) { // 2 minutes
        return;
      }
    }
    
    setState(() {
      _locationHistory.add(newLocationData);
      _updateHeatMap();
    });
    
    await _saveLocationData();
    
    // Update last tracking time
    _lastTrackingTime = DateTime.now();
    await _prefs?.setInt('last_tracking_time', DateTime.now().millisecondsSinceEpoch);
  }

  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const double earthRadius = 6371000; // Earth's radius in meters
    double dLat = _degreesToRadians(lat2 - lat1);
    double dLon = _degreesToRadians(lon2 - lon1);
    double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degreesToRadians(lat1)) * math.cos(_degreesToRadians(lat2)) *
        math.sin(dLon / 2) * math.sin(dLon / 2);
    double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  double _degreesToRadians(double degrees) {
    return degrees * (math.pi / 180);
  }

  void _startBackgroundTracking() {
    // Cancel existing tasks first
    Workmanager().cancelAll();
    
    // Register periodic background task with more frequent updates
    Workmanager().registerPeriodicTask(
      "locationTrackingTask",
      "locationTracking",
      frequency: Duration(minutes: 15), // Minimum allowed by system
      initialDelay: Duration(minutes: 1),
      constraints: Constraints(
        networkType: NetworkType.notRequired,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
        requiresStorageNotLow: false,
      ),
      inputData: {
        'tracking_enabled': true,
        'start_time': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  void _stopBackgroundTracking() {
    Workmanager().cancelAll();
  }

  void _stopLocationTracking() {
    setState(() {
      _isTracking = false;
    });
    
    // Save tracking state
    _prefs?.setBool('was_tracking', false);
    
    _stopForegroundTracking();
    _stopBackgroundTracking();
  }

  void _updateHeatMap() {
    Map<String, List<Map<String, dynamic>>> locationGroups = {};
    Set<Circle> circles = {};

    // Group locations by proximity (more precise grouping)
    for (Map<String, dynamic> location in _locationHistory) {
      double lat = location['latitude'];
      double lng = location['longitude'];
      
      // Round to 4 decimal places (~11m precision) for better clustering
      String key = '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
      
      if (!locationGroups.containsKey(key)) {
        locationGroups[key] = [];
      }
      locationGroups[key]!.add(location);
    }

    // Create heat map circles with improved visualization
    locationGroups.forEach((key, locations) {
      List<String> coords = key.split(',');
      double lat = double.parse(coords[0]);
      double lng = double.parse(coords[1]);

      int visitCount = locations.length;
      
      // Enhanced intensity calculation
      double intensity = math.min(visitCount / 20.0, 1.0); // Adjusted threshold
      Color circleColor = _getHeatMapColor(intensity);
      
      // Variable radius based on visit count
      double radius = math.max(40, math.min(120, visitCount * 8));

      circles.add(Circle(
        circleId: CircleId(key),
        center: LatLng(lat, lng),
        radius: radius,
        fillColor: circleColor.withOpacity(0.25),
        strokeColor: circleColor.withOpacity(0.6),
        strokeWidth: 1,
        onTap: () => _showLocationDetails(locations, lat, lng),
      ));
    });

    setState(() {
      _heatMapCircles = circles;
    });
  }

  Color _getHeatMapColor(double intensity) {
    // Minimalistic color palette
    if (intensity < 0.2) {
      return Color(0xFF6366F1); // Indigo
    } else if (intensity < 0.4) {
      return Color(0xFF10B981); // Emerald
    } else if (intensity < 0.6) {
      return Color(0xFFF59E0B); // Amber
    } else if (intensity < 0.8) {
      return Color(0xFFEF4444); // Red
    } else {
      return Color(0xFFDC2626); // Dark red
    }
  }

  void _showLocationDetails(List<Map<String, dynamic>> locations, double lat, double lng) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Location Details',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1F2937),
                ),
              ),
              SizedBox(height: 16),
              _buildDetailRow('Coordinates', '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}'),
              _buildDetailRow('Total visits', '${locations.length}'),
              _buildDetailRow('Est. time', '${(locations.length * 5)} minutes'),
              SizedBox(height: 16),
              Text(
                'Recent visits',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF6B7280),
                ),
              ),
              SizedBox(height: 8),
              Container(
                constraints: BoxConstraints(maxHeight: 120),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: math.min(5, locations.length),
                  itemBuilder: (context, index) {
                    var loc = locations[index];
                    return Padding(
                      padding: EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${_formatTime(DateTime.fromMillisecondsSinceEpoch(loc['timestamp']))}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF9CA3AF),
                        ),
                      ),
                    );
                  },
                ),
              ),
              SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Close',
                    style: TextStyle(
                      color: Color(0xFF6366F1),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: Color(0xFF6B7280),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(0xFF1F2937),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _clearHeatMap() {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Clear all data?',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1F2937),
                ),
              ),
              SizedBox(height: 8),
              Text(
                'This will remove all location history and cannot be undone.',
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF6B7280),
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(
                        'Cancel',
                        style: TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _locationHistory.clear();
                          _heatMapCircles.clear();
                          _lastTrackingTime = null;
                        });
                        
                        // Clear saved data
                        _prefs?.remove('location_history');
                        _prefs?.remove('last_tracking_time');
                        _prefs?.remove('consecutive_bg_updates');
                        
                        Navigator.pop(context);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Color(0xFFEF4444),
                        foregroundColor: Colors.white,
                      ),
                      child: Text('Clear'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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
      if (difference.inMinutes < 2) {
        return 'Active';
      } else if (difference.inMinutes < 20) {
        return 'Background';
      } else {
        return 'Inactive';
      }
    }
    return 'Starting';
  }

  void _showTrackingInfo() {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tracking Started',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1F2937),
                ),
              ),
              SizedBox(height: 16),
              Text(
                'Location tracking is now active and will continue in the background.',
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF6B7280),
                ),
              ),
              SizedBox(height: 16),
              Container(
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Color(0xFFF9FAFB),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Color(0xFFE5E7EB)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'For best results:',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF1F2937),
                      ),
                    ),
                    SizedBox(height: 8),
                    Text('• Allow "Always" location permission', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                    Text('• Disable battery optimization', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                    Text('• Keep app in recent apps', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                  ],
                ),
              ),
              SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Got it',
                    style: TextStyle(
                      color: Color(0xFF6366F1),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  int _getBackgroundUpdateCount() {
    return _prefs?.getInt('consecutive_bg_updates') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Location Tracker'),
        actions: [
          IconButton(
            icon: Icon(Icons.help_outline, size: 20),
            onPressed: () => _showLegend(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // Clean stats header
          Container(
            margin: EdgeInsets.all(16),
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Tracking Status',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                      SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: _isTracking ? Color(0xFF10B981) : Color(0xFF6B7280),
                              shape: BoxShape.circle,
                            ),
                          ),
                          SizedBox(width: 8),
                          Text(
                            _getTrackingStatus(),
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1F2937),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 40,
                  width: 1,
                  color: Color(0xFFE5E7EB),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Data Points',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '${_locationHistory.length}',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1F2937),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 40,
                  width: 1,
                  color: Color(0xFFE5E7EB),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Heat Points',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '${_heatMapCircles.length}',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1F2937),
                        ),
                      ),
                    ],
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
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
            ),
            child: SizedBox(
              width: 145,
              height: 59,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    onPressed: _isTracking ? _stopLocationTracking : _startLocationTracking,
                    icon: Icon(
                      _isTracking ? Icons.stop_rounded : Icons.play_arrow_rounded,
                      color: _isTracking ? Colors.red : Colors.green,
                      size: 30,
                    ),
                  ),
                  IconButton(
                    onPressed: _centerOnCurrentLocation,
                    icon: Icon(
                      Icons.my_location,
                      size: 28,
                      color: Colors.blue,
                    ),
                  ),
                  IconButton(
                    onPressed: () => _showLegend(context),
                    icon: Icon(
                      Icons.info_rounded,
                      color: Colors.grey[700],
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
            child: Icon(Icons.clear_rounded, color: Colors.white, size: 28),
            backgroundColor: Colors.red,
            heroTag: "clear",
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String title, String value) {
    return Card(
      color: Colors.black87,
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(fontSize: 14, color: Colors.white70),
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
          title: Text('📍 Enhanced Heat Map Guide'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('🎨 Heat map colors (visit frequency):'),
                SizedBox(height: 8),
                _buildLegendItem(Colors.blue, 'Low activity (1-4 visits)'),
                _buildLegendItem(Colors.green, 'Medium activity (5-8 visits)'),
                _buildLegendItem(Colors.orange, 'High activity (9-12 visits)'),
                _buildLegendItem(Colors.deepOrange, 'Very high (13-16 visits)'),
                _buildLegendItem(Colors.red, 'Extreme activity (17+ visits)'),
                SizedBox(height: 12),
                Text('ℹ️ Features:', style: TextStyle(fontWeight: FontWeight.bold)),
                Text('• Tap circles for location details'),
                Text('• Automatic data saving'),
                Text('• Smart duplicate filtering'),
                Text('• Enhanced background tracking'),
                Text('• Tracks last 2000 locations'),
                SizedBox(height: 12),
                Text('⚠️ Important Limitations:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange[700])),
                Text('• Cannot track when phone is OFF'),
                Text('• Background updates limited to 15min'),
                Text('• Battery optimization may affect tracking'),
                Text('• iOS has stricter background limits'),
              ],
            ),
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