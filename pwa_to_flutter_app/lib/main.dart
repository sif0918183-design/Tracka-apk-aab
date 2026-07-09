import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'; 
import 'package:audioplayers/audioplayers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as fln;
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'webview_popup.dart';

// أنواع إشعارات منصة السفر
const _travelTypes = {'DRIVER_OFFER', 'DRIVER_SELECTED', 'NEW_CHAT_MESSAGE'};

// ✅ معرف القناة الثابت
const String _emergencyChannelId = 'emergency_channel_default';
const String _emergencyChannelName = 'تنبيهات الطوارئ - تراكا';

// ✅ متغيرات عالمية للصوت والاهتزاز (غير static)
AudioPlayer? _globalAudioPlayer;
Timer? _globalAlertTimer;
bool _globalIsAlertPlaying = false;

String? _extractRideId(Map<String, dynamic> data) {
  dynamic rideId = data['ride_id'] ?? data['rideId'];
  if (rideId == null && data['payload'] != null) {
    try {
      final payloadData = data['payload'] is String ? jsonDecode(data['payload']) : data['payload'];
      rideId = payloadData['ride_id'] ?? payloadData['rideId'];
    } catch (_) {}
  }
  return rideId?.toString();
}

Future<bool> _isDuplicateRide(String? rideId) async {
  if (rideId == null) return false;
  final prefs = await SharedPreferences.getInstance();
  final String key = 'handled_ride_$rideId';
  final lastHandled = prefs.getInt(key);
  final now = DateTime.now().millisecondsSinceEpoch;

  if (lastHandled != null && (now - lastHandled) < 300000) {
    return true;
  }

  await prefs.setInt(key, now);
  return false;
}

// ✅ تشغيل الصوت والاهتزاز المتكرر في الخلفية
void _playAlertSoundInBackground() {
  _globalIsAlertPlaying = true;
  
  // ✅ تشغيل الاهتزاز
  _vibratePhoneBackground();

  // ✅ تشغيل الصوت
  try {
    _globalAudioPlayer = AudioPlayer();
    _globalAudioPlayer!.setVolume(1.0);
    _globalAudioPlayer!.setReleaseMode(ReleaseMode.loop);
    _globalAudioPlayer!.play(AssetSource('sounds/ride_alert.mp3'));
    
    _globalAlertTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_globalIsAlertPlaying) {
        try {
          if (_globalAudioPlayer?.state == PlayerState.stopped || 
              _globalAudioPlayer?.state == PlayerState.completed) {
            await _globalAudioPlayer!.play(AssetSource('sounds/ride_alert.mp3'));
          }
        } catch (_) {}
      } else {
        timer.cancel();
      }
    });
  } catch (_) {
    try {
      _globalAudioPlayer = AudioPlayer();
      _globalAudioPlayer!.setVolume(1.0);
      _globalAudioPlayer!.setReleaseMode(ReleaseMode.loop);
      _globalAudioPlayer!.play(AssetSource('ride_request_sound.mp3'));
    } catch (_) {}
  }
  
  // ✅ إيقاف تلقائي بعد 35 ثانية
  Future.delayed(const Duration(seconds: 35), () {
    _stopAlertSoundInBackground();
  });
}

void _vibratePhoneBackground() {
  try {
    Vibration.hasVibrator().then((hasVibrator) {
      if (hasVibrator == true) {
        Vibration.vibrate(pattern: [0, 500, 300, 500, 300, 500, 300, 500, 300, 500], repeat: 0);
      }
    });
  } catch (_) {}
}

void _stopAlertSoundInBackground() {
  _globalIsAlertPlaying = false;
  _globalAlertTimer?.cancel();
  _globalAlertTimer = null;
  _globalAudioPlayer?.stop();
  _globalAudioPlayer?.dispose();
  _globalAudioPlayer = null;
  try {
    Vibration.cancel();
  } catch (_) {}
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  Map<String, dynamic> data = message.data;
  final String notifType = data['type']?.toString() ?? '';
  final bool isTravelNotif = _travelTypes.contains(notifType);

  if (!isTravelNotif) {
    String? rideId = _extractRideId(data);
    if (await _isDuplicateRide(rideId)) return;
    
    // ✅ تشغيل الصوت والاهتزاز المتكرر عند استلام الإشعار في الخلفية
    _playAlertSoundInBackground();
  }

  final fln.FlutterLocalNotificationsPlugin notifications = fln.FlutterLocalNotificationsPlugin();
  const android = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
  await notifications.initialize(const fln.InitializationSettings(android: android));

  String title = message.notification?.title ?? (isTravelNotif ? 'تراكا' : '🚨 طلب رحلة جديد');
  String body = message.notification?.body ?? (isTravelNotif ? 'لديك إشعار جديد' : 'يوجد طلب رحلة جديد في انتظارك');

  if (isTravelNotif) {
    await notifications.show(
      DateTime.now().millisecond, title, body,
      const fln.NotificationDetails(
        android: fln.AndroidNotificationDetails(
          'travel_notifications',
          'إشعارات السفر - تراكا',
          importance: fln.Importance.high,
          priority: fln.Priority.high,
          playSound: true,
          enableVibration: true,
          channelShowBadge: true,
          visibility: fln.NotificationVisibility.public,
        ),
      ),
      payload: jsonEncode(data),
    );
  } else {
    String? rideId = _extractRideId(data);
    await notifications.show(
      rideId?.hashCode ?? DateTime.now().millisecond,
      title,
      body,
      fln.NotificationDetails(
        android: fln.AndroidNotificationDetails(
          _emergencyChannelId,
          _emergencyChannelName,
          importance: fln.Importance.max,
          priority: fln.Priority.max,
          ongoing: true,
          category: fln.AndroidNotificationCategory.alarm,
          playSound: true,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 500, 300, 500, 300, 500, 300, 500, 300, 500, 300, 500]),
          sound: null,
          channelShowBadge: true,
          visibility: fln.NotificationVisibility.public,
          timeoutAfter: null,
        ),
      ),
      payload: jsonEncode(data),
    );
  }
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(MyTaskHandler());
}

class MyTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  if (kDebugMode && !kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  await [
    Permission.notification,
    Permission.location,
    Permission.locationAlways,
    Permission.camera,
    Permission.ignoreBatteryOptimizations,
  ].request();
  
  _initForegroundTask();
  runApp(const DriverApp());
}

void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'foreground_service',
      channelName: 'خدمة تراكا تعمل حالياً',
      channelImportance: NotificationChannelImportance.MAX,
      priority: NotificationPriority.HIGH,
    ),
    iosNotificationOptions: const IOSNotificationOptions(showNotification: true, playSound: false),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(5000),
      autoRunOnBoot: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

class DriverApp extends StatelessWidget {
  const DriverApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: DriverHome(),
    );
  }
}

class DriverHome extends StatefulWidget {
  const DriverHome({super.key});
  @override
  State<DriverHome> createState() => _DriverHomeState();
}

class _DriverHomeState extends State<DriverHome> {
  final supabase = Supabase.instance.client;
  final fln.FlutterLocalNotificationsPlugin notifications = fln.FlutterLocalNotificationsPlugin();
  InAppWebViewController? web;
  bool _isPageLoaded = false;
  String? driverId;
  String? fcmToken;
  String? _pendingUrl;
  RealtimeChannel? channel;
  Timer? statusSyncTimer;
  StreamSubscription<ConnectivityResult>? connectivitySubscription;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _initFirebaseMessaging();
    _restoreDriver();
    _initConnectivity();
  }

  @override
  void dispose() {
    _stopAlertSound();
    statusSyncTimer?.cancel();
    connectivitySubscription?.cancel();
    _globalAudioPlayer?.dispose();
    super.dispose();
  }

  Future<void> _initNotifications() async {
    const androidInit = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
    await notifications.initialize(
      const fln.InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: (details) {
        _stopAlertSound();
        if (details.payload != null) _handleNotificationClick(jsonDecode(details.payload!));
      }
    );

    final androidImplementation = notifications.resolvePlatformSpecificImplementation<fln.AndroidFlutterLocalNotificationsPlugin>();

    if (androidImplementation != null) {
      // ✅ حذف القنوات القديمة
      for (int i = 10; i <= 20; i++) {
        try {
          await androidImplementation.deleteNotificationChannel('emergency_channel_v$i');
          await androidImplementation.deleteNotificationChannel('emergency_channel_backup_v$i');
        } catch (_) {}
      }
      
      try {
        await androidImplementation.deleteNotificationChannel('emergency_channel_v11');
        await androidImplementation.deleteNotificationChannel('emergency_channel_v12');
        await androidImplementation.deleteNotificationChannel('emergency_channel_v13');
        await androidImplementation.deleteNotificationChannel('emergency_channel_v14');
        await androidImplementation.deleteNotificationChannel('emergency_channel_backup');
      } catch (_) {}

      // ✅ إنشاء قناة الطوارئ الرئيسية
      final emergencyChan = fln.AndroidNotificationChannel(
        _emergencyChannelId,
        _emergencyChannelName,
        description: 'قناة الطوارئ للرحلات الجديدة - صوت عالٍ واهتزاز قوي',
        importance: fln.Importance.max,
        playSound: true,
        enableVibration: true,
        audioAttributesUsage: fln.AudioAttributesUsage.alarm,
      );
      await androidImplementation.createNotificationChannel(emergencyChan);
      
      // ✅ قناة إشعارات السفر (هادئة)
      const travelChan = fln.AndroidNotificationChannel(
        'travel_notifications',
        'إشعارات السفر - تراكا',
        description: 'إشعارات قبول الرحلات والمحادثات',
        importance: fln.Importance.high,
        playSound: true,
        enableVibration: true,
      );
      await androidImplementation.createNotificationChannel(travelChan);
      
      print('✅ تم إنشاء قناة الإشعارات: $_emergencyChannelId');
    }
  }

  Future<void> _initFirebaseMessaging() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    fcmToken = await messaging.getToken();
    if (fcmToken != null) _sendTokenToPWA(fcmToken!);
    messaging.onTokenRefresh.listen((newToken) { 
      fcmToken = newToken; 
      _sendTokenToPWA(newToken); 
    });
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _stopAlertSound();
      _handleNotificationClick(message.data);
    });
    messaging.getInitialMessage().then((message) { 
      if (message != null) {
        _stopAlertSound();
        _handleNotificationClick(message.data); 
      }
    });
    FirebaseMessaging.onMessage.listen((message) {
      // ✅ عندما يكون التطبيق في المقدمة
      _playAlertSound();
      _handleFcmMessage(message);
    });
  }

  void _handleNotificationClick(Map<String, dynamic> data) {
    final String notifType = data['type']?.toString() ?? '';
    final bool isTravelNotif = _travelTypes.contains(notifType);

    _stopAlertSound();

    if (isTravelNotif) {
      const String travelUrl = 'https://tracka.zoonasd.com/driver_app/travel-platform.html';
      if (web != null) {
        web!.loadUrl(urlRequest: URLRequest(url: WebUri(travelUrl)));
      } else {
        setState(() => _pendingUrl = travelUrl);
      }
      return;
    }

    dynamic rideId = data['ride_id'] ?? data['rideId'];

    if (rideId == null && data['payload'] != null) {
      try {
        final payloadData = data['payload'] is String ? jsonDecode(data['payload']) : data['payload'];
        rideId = payloadData['ride_id'] ?? payloadData['rideId'];
      } catch (_) {}
    }

    if (rideId != null) {
      final url = "https://tracka.zoonasd.com/driver_app/accept-ride.html?id=$rideId";
      if (web != null) {
        web!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
      } else {
        setState(() => _pendingUrl = url);
      }
    }
  }

  void _handleFcmMessage(RemoteMessage message) async {
    Map<String, dynamic> data = Map<String, dynamic>.from(message.data);
    final String notifType = data['type']?.toString() ?? '';
    final bool isTravelNotif = _travelTypes.contains(notifType);

    if (isTravelNotif) {
      await _showTravelNotification(data, message.notification);
      return;
    }

    String? rideId = _extractRideId(data);
    if (await _isDuplicateRide(rideId)) return;

    _playAlertSound();
    await _showLocalNotification(data);
    _showRideRequestModal(data);
    await _sendToPWA(data);
  }

  void _sendTokenToPWA(String token) async {
    if (web != null && _isPageLoaded) {
      await web!.evaluateJavascript(source: "if(typeof window.setFCMToken === 'function') window.setFCMToken('$token');");
    }
  }

  Future<void> _restoreDriver() async {
    final prefs = await SharedPreferences.getInstance();
    driverId = prefs.getString('driver_id');
    final lastUrl = prefs.getString('last_url');
    if (_pendingUrl == null && lastUrl != null && lastUrl.isNotEmpty) {
      if (web != null) web!.loadUrl(urlRequest: URLRequest(url: WebUri(lastUrl)));
      else setState(() => _pendingUrl = lastUrl);
    }
    if (driverId != null) { 
      _listenForRides(); 
      _startStatusSyncWithPWA(); 
      _startForegroundService(); 
    }
  }

  Future<void> _saveDriver(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('driver_id', id);
    driverId = id;
    _listenForRides();
    _notifyPWAOfDriver(id);
    _startForegroundService();
  }

  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      notificationTitle: 'Tracka يعمل في الخلفية',
      notificationText: 'جاهز لاستقبال طلبات الرحلات',
      callback: startCallback,
    );
  }

  void _initConnectivity() {
    connectivitySubscription = Connectivity().onConnectivityChanged.listen((result) {
      if (result != ConnectivityResult.none && driverId != null) { 
        _listenForRides(); 
        _updateDriverStatusInSupabase(true); 
      }
    });
  }

  void _listenForRides() {
    if (driverId == null) return;
    channel?.unsubscribe();
    channel = supabase.channel('ride_requests_$driverId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'ride_requests',
        filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'driver_id', value: driverId!),
        callback: (payload) async {
          final data = payload.newRecord;
          Map<String, dynamic> rideData = data != null ? Map<String, dynamic>.from(data) : {};
          String? rideId = _extractRideId(rideData);
          if (await _isDuplicateRide(rideId)) return;

          _playAlertSound();
          await _showLocalNotification(rideData);
          _showRideRequestModal(rideData);
          await _sendToPWA(rideData);
        },
      )..subscribe();
  }

  void _playAlertSound() {
    _stopAlertSound();
    _globalIsAlertPlaying = true;

    // ✅ اهتزاز
    _vibratePhone();

    // ✅ صوت من assets
    try {
      _globalAudioPlayer = AudioPlayer();
      _globalAudioPlayer!.setVolume(1.0);
      _globalAudioPlayer!.setReleaseMode(ReleaseMode.loop);
      _globalAudioPlayer!.play(AssetSource('sounds/ride_alert.mp3'));
      
      _globalAlertTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
        if (_globalIsAlertPlaying) {
          try {
            if (_globalAudioPlayer?.state == PlayerState.stopped || 
                _globalAudioPlayer?.state == PlayerState.completed) {
              await _globalAudioPlayer!.play(AssetSource('sounds/ride_alert.mp3'));
            }
          } catch (_) {}
        } else {
          timer.cancel();
        }
      });
    } catch (_) {
      try {
        _globalAudioPlayer = AudioPlayer();
        _globalAudioPlayer!.setVolume(1.0);
        _globalAudioPlayer!.setReleaseMode(ReleaseMode.loop);
        _globalAudioPlayer!.play(AssetSource('ride_request_sound.mp3'));
      } catch (_) {}
    }

    Future.delayed(const Duration(seconds: 35), () {
      _stopAlertSound();
    });
  }

  void _vibratePhone() async {
    try {
      bool? hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator == true) {
        Vibration.vibrate(pattern: [
          0, 600, 200, 600, 200, 600, 200, 600, 
          200, 600, 200, 600, 200, 600, 200, 600,
          200, 600, 200, 600
        ], repeat: 0);
        
        for (int i = 2; i <= 12; i += 2) {
          Future.delayed(Duration(seconds: i), () {
            if (_globalIsAlertPlaying) {
              Vibration.vibrate(pattern: [0, 400, 200, 400, 200, 400], repeat: 0);
            }
          });
        }
      }
    } catch (_) {}
  }

  void _stopAlertSound() {
    _globalIsAlertPlaying = false;
    _globalAlertTimer?.cancel();
    _globalAlertTimer = null;
    _globalAudioPlayer?.stop();
    _globalAudioPlayer?.dispose();
    _globalAudioPlayer = null;
    try {
      Vibration.cancel();
    } catch (_) {}
  }

  Future<void> _showLocalNotification(Map<String, dynamic> data) async {
    try {
      String name = data['customer_name'] ?? 'عميل';
      String amount = data['amount']?.toString() ?? '0';
      String? rideId = _extractRideId(data);

      await notifications.show(
        rideId?.hashCode ?? DateTime.now().millisecond,
        '🚨 طلب رحلة جديد',
        '$name - $amount SDG',
        fln.NotificationDetails(
          android: fln.AndroidNotificationDetails(
            _emergencyChannelId,
            _emergencyChannelName,
            importance: fln.Importance.max,
            priority: fln.Priority.max,
            ongoing: true,
            category: fln.AndroidNotificationCategory.alarm,
            playSound: true,
            enableVibration: true,
            vibrationPattern: Int64List.fromList([0, 500, 300, 500, 300, 500, 300, 500, 300, 500, 300, 500]),
            sound: null,
            channelShowBadge: true,
            visibility: fln.NotificationVisibility.public,
            timeoutAfter: null,
          ),
        ),
        payload: jsonEncode(data),
      );
    } catch (_) {}
  }

  Future<void> _showTravelNotification(Map<String, dynamic> data, RemoteNotification? notif) async {
    try {
      final String title = notif?.title ?? 'تراكا';
      final String body = notif?.body ?? 'لديك إشعار جديد';
      await notifications.show(
        DateTime.now().millisecond, title, body,
        const fln.NotificationDetails(
          android: fln.AndroidNotificationDetails(
            'travel_notifications',
            'إشعارات السفر - تراكا',
            importance: fln.Importance.high,
            priority: fln.Priority.high,
            playSound: true,
            enableVibration: true,
          ),
        ),
        payload: jsonEncode(data),
      );
    } catch (_) {}
  }

  void _showRideRequestModal(Map<String, dynamic> data) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('طلب رحلة جديد', textAlign: TextAlign.center),
        content: Text("${data['customer_name'] ?? 'عميل'} - ${data['amount'] ?? 0} SDG"),
        actions: [
          ElevatedButton(
            onPressed: () { 
              _stopAlertSound();
              _acceptRide(data); 
              Navigator.pop(context); 
            }, 
            child: const Text('قبول')
          ),
          TextButton(
            onPressed: () { 
              _stopAlertSound();
              Navigator.pop(context); 
            }, 
            child: const Text('تجاهل')
          )
        ],
      ),
    );
  }

  Future<void> _acceptRide(Map<String, dynamic> data) async {
    _stopAlertSound();
    try { 
      await supabase.from('ride_requests').update({'status': 'accepted'}).eq('ride_id', data['ride_id'] ?? data['rideId']).eq('driver_id', driverId!); 
    } catch (_) {}
    if (web != null) await web!.evaluateJavascript(source: "if(typeof handleRideRequest === 'function') handleRideRequest(${jsonEncode(data)});");
  }

  void _stopAlerts() {
    _stopAlertSound();
    Vibration.cancel();
    notifications.cancelAll();
  }

  Future<void> _sendToPWA(Map<String, dynamic> data) async {
    if (web == null) return;
    await web!.evaluateJavascript(source: "if(typeof handleRideRequest === 'function') handleRideRequest(${jsonEncode(data)});");
  }

  void _notifyPWAOfDriver(String id) { 
    if (web == null) return; 
    web!.evaluateJavascript(source: "localStorage.setItem('driver_id', '$id');"); 
  }

  void _startStatusSyncWithPWA() {
    statusSyncTimer?.cancel();
    statusSyncTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (web == null || driverId == null) return;
      final res = await web!.evaluateJavascript(source: "localStorage.getItem('driver_forever_online')");
      if (res != null) _updateDriverStatusInSupabase(res == 'true');
    });
  }

  Future<void> _updateDriverStatusInSupabase(bool isOnline) async {
    if (driverId == null) return;
    try { 
      await supabase.from('driver_locations').upsert({
        'driver_id': driverId, 
        'is_online': isOnline, 
        'last_seen': DateTime.now().toIso8601String()
      }).timeout(const Duration(seconds: 15)); 
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.white,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
        child: SafeArea(
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(_pendingUrl ?? 'https://tracka.zoonasd.com/')),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              geolocationEnabled: true,
              useShouldOverrideUrlLoading: true,
              userAgent: "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36",
            ),
            onWebViewCreated: (controller) {
              web = controller;
              controller.addJavaScriptHandler(handlerName: 'driverLogin', callback: (args) { 
                if (args.isNotEmpty && args[0] is Map) _saveDriver(args[0]['driverId'].toString()); 
              });
              controller.addJavaScriptHandler(handlerName: 'stopAlerts', callback: (args) { 
                _stopAlerts(); 
              });

              if (_pendingUrl != null) {
                controller.loadUrl(urlRequest: URLRequest(url: WebUri(_pendingUrl!)));
              }
            },
            onGeolocationPermissionsShowPrompt: (controller, origin) async => 
                GeolocationPermissionShowPromptResponse(origin: origin, allow: true, retain: true),
            onLoadStop: (controller, url) async {
              _isPageLoaded = true;
              if (url != null) {
                final String currentUrl = url.toString();
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('last_url', currentUrl);

                if (!currentUrl.contains('accept-ride.html')) {
                  _stopAlerts();
                }
              }
              if (fcmToken != null) _sendTokenToPWA(fcmToken!);
              _startDriverSync();
            },
            shouldOverrideUrlLoading: (controller, nav) async {
              final uri = nav.request.url!;
              if (['whatsapp', 'tel', 'sms', 'mailto'].contains(uri.scheme) || uri.toString().contains('wa.me')) {
                try { await launchUrl(uri, mode: LaunchMode.externalApplication); } catch (_) {}
                return NavigationActionPolicy.CANCEL;
              }
              return NavigationActionPolicy.ALLOW;
            },
          ),
        ),
      ),
    );
  }

  void _startDriverSync() {
    Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (web == null) return;
      final res = await web!.evaluateJavascript(source: "localStorage.getItem('driver_id')");
      if (res != null && res != 'null' && res != driverId) _saveDriver(res);
    });
  }
}