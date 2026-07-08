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
import 'webview_popup.dart';

// أنواع إشعارات منصة السفر — هادئة بدون صوت مزعج أو مودال
const _travelTypes = {'DRIVER_OFFER', 'DRIVER_SELECTED', 'NEW_CHAT_MESSAGE'};

// ✅ متغيرات للتحكم في تشغيل الصوت والاهتزاز
AudioPlayer? _audioPlayer;
Timer? _alertTimer;
bool _isAlertPlaying = false;

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

  if (lastHandled != null && (now - lastHandled) < 300000) { // 5 minutes
    return true;
  }

  await prefs.setInt(key, now);
  return false;
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  Map<String, dynamic> data = message.data;
  final String notifType = data['type']?.toString() ?? '';
  final bool isTravelNotif = _travelTypes.contains(notifType);

  // فحص التكرار فقط لطلبات الرحلات العادية
  if (!isTravelNotif) {
    String? rideId = _extractRideId(data);
    if (await _isDuplicateRide(rideId)) return;
  }

  final fln.FlutterLocalNotificationsPlugin notifications = fln.FlutterLocalNotificationsPlugin();
  const android = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
  await notifications.initialize(const fln.InitializationSettings(android: android));

  String title = message.notification?.title ?? (isTravelNotif ? 'تراكا' : 'طلب رحلة جديد ');
  String body = message.notification?.body ?? (isTravelNotif ? 'لديك إشعار جديد' : 'لديك طلب رحلة جديد في انتظارك');

  if (isTravelNotif) {
    // إشعار هادئ لمنصة السفر
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
    // ✅ إشعار طارئ محسّن لطلبات الرحلات العادية
    String? rideId = _extractRideId(data);
    await notifications.show(
      rideId?.hashCode ?? DateTime.now().millisecond, title, body,
      fln.NotificationDetails(
        android: fln.AndroidNotificationDetails(
          'emergency_channel_v11',
          'تنبيهات الطوارئ - تراكا',
          importance: fln.Importance.max,
          priority: fln.Priority.max,
          fullScreenIntent: true,
          ongoing: true,
          category: fln.AndroidNotificationCategory.call,
          playSound: true,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 500, 300, 500, 300, 500, 300, 500]),
          sound: const fln.RawResourceAndroidNotificationSound('ride_request_sound'),
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

  await Supabase.initialize(
    url: 'https://zsmlyiygjagmhnglrhoa.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpzbWx5aXlnamFnbWhuZ2xyaG9hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU5NDc3NjMsImV4cCI6MjA4MTUyMzc2M30.QviVinAng-ILq0umvI5UZCFEvNpP3nI0kW_hSaXxNps',
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
    _audioPlayer?.dispose();
    super.dispose();
  }

  Future<void> _initNotifications() async {
    const androidInit = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
    await notifications.initialize(
      const fln.InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: (details) {
        if (details.payload != null) _handleNotificationClick(jsonDecode(details.payload!));
      }
    );

    final androidImplementation = notifications.resolvePlatformSpecificImplementation<fln.AndroidFlutterLocalNotificationsPlugin>();

    // ✅ قناة طلبات الرحلات العادية (محسّنة مع صوت واهتزاز قوي)
    const urgentChan = fln.AndroidNotificationChannel(
      'emergency_channel_v11',
      'تنبيهات الطوارئ - تراكا',
      description: 'هذه القناة مخصصة لطلبات الرحلات الهامة جداً',
      importance: fln.Importance.max,
      playSound: true,
      enableVibration: true,
      audioAttributesUsage: fln.AudioAttributesUsage.notificationRingtone,
      sound: fln.RawResourceAndroidNotificationSound('ride_request_sound'),
    );
    await androidImplementation?.createNotificationChannel(urgentChan);

    // ✅ قناة ثانية للنسخ الاحتياطي (بصوت مختلف)
    const backupChan = fln.AndroidNotificationChannel(
      'emergency_channel_backup',
      'تنبيهات الطوارئ - تراكا (نسخة احتياطية)',
      description: 'قناة احتياطية للإشعارات الطارئة',
      importance: fln.Importance.max,
      playSound: true,
      enableVibration: true,
      audioAttributesUsage: fln.AudioAttributesUsage.notificationRingtone,
      sound: fln.RawResourceAndroidNotificationSound('ride_request_sound'),
    );
    await androidImplementation?.createNotificationChannel(backupChan);

    // قناة منصة السفر (صوت عادي هادئ)
    const travelChan = fln.AndroidNotificationChannel(
      'travel_notifications',
      'إشعارات السفر - تراكا',
      description: 'إشعارات قبول الرحلات والمحادثات في منصة السفر',
      importance: fln.Importance.high,
      playSound: true,
      enableVibration: true,
    );
    await androidImplementation?.createNotificationChannel(travelChan);
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
    FirebaseMessaging.onMessageOpenedApp.listen((message) => _handleNotificationClick(message.data));
    messaging.getInitialMessage().then((message) { 
      if (message != null) _handleNotificationClick(message.data); 
    });
    FirebaseMessaging.onMessage.listen((message) => _handleFcmMessage(message));
  }

  void _handleNotificationClick(Map<String, dynamic> data) {
    final String notifType = data['type']?.toString() ?? '';
    final bool isTravelNotif = _travelTypes.contains(notifType);

    // ✅ إيقاف الصوت والاهتزاز عند النقر على الإشعار
    _stopAlertSound();

    // إشعارات منصة السفر → فتح صفحة السفر مباشرة
    if (isTravelNotif) {
      const String travelUrl = 'https://tracka.zoonasd.com/driver_app/travel-platform.html';
      if (web != null) {
        web!.loadUrl(urlRequest: URLRequest(url: WebUri(travelUrl)));
      } else {
        setState(() => _pendingUrl = travelUrl);
      }
      return;
    }

    // طلبات الرحلات العادية → accept-ride.html
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
      // إشعار هادئ فقط — بدون صوت مزعج أو مودال
      await _showTravelNotification(data, message.notification);
      return;
    }

    // طلب رحلة عادي — فحص التكرار + إشعار طارئ + مودال
    String? rideId = _extractRideId(data);
    if (await _isDuplicateRide(rideId)) return;

    // ✅ تشغيل الصوت والاهتزاز فوراً
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

          // ✅ تشغيل الصوت والاهتزاز للرحلات القادمة من Supabase
          _playAlertSound();

          await _showLocalNotification(rideData);
          _showRideRequestModal(rideData);
          await _sendToPWA(rideData);
        },
      )..subscribe();
  }

  // ✅ دالة محسّنة لتشغيل الصوت والاهتزاز المتكرر
  void _playAlertSound() {
    _stopAlertSound();
    _isAlertPlaying = true;

    // ✅ اهتزاز متكرر (تم إصلاح الـ async)
    _vibratePhone();

    // ✅ تشغيل الصوت عبر AudioPlayer
    try {
      _audioPlayer = AudioPlayer();
      _audioPlayer!.play(AssetSource('sounds/ride_alert.mp3'));
      
      // ✅ تكرار الصوت كل 3 ثوانٍ
      _alertTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
        if (_isAlertPlaying) {
          try {
            await _audioPlayer!.play(AssetSource('sounds/ride_alert.mp3'));
          } catch (_) {}
        } else {
          timer.cancel();
        }
      });
    } catch (_) {
      // ✅ في حال فشل تشغيل الصوت المخصص، استخدام الصوت الافتراضي عبر النوتيفيكيشن
      _playFallbackSound();
    }

    // ✅ إيقاف الصوت تلقائياً بعد 30 ثانية
    Future.delayed(const Duration(seconds: 30), () {
      _stopAlertSound();
    });
  }

  // ✅ دالة منفصلة للاهتزاز
  void _vibratePhone() async {
    try {
      if (await Vibration.hasVibrator() ?? false) {
        Vibration.vibrate(pattern: [0, 500, 300, 500, 300, 500, 300, 500, 300, 500], repeat: 0);
      }
    } catch (_) {}
  }

  // ✅ تشغيل صوت احتياطي عبر الإشعارات
  void _playFallbackSound() async {
    try {
      final testNotif = fln.NotificationDetails(
        android: fln.AndroidNotificationDetails(
          'emergency_channel_backup',
          'تنبيهات الطوارئ - تراكا',
          importance: fln.Importance.max,
          priority: fln.Priority.max,
          playSound: true,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 500, 300, 500]),
          category: fln.AndroidNotificationCategory.call,
        ),
      );
      await notifications.show(
        999,
        '🔔 تنبيه',
        'طلب رحلة جديد',
        testNotif,
      );
    } catch (_) {}
  }

  // ✅ إيقاف الصوت والاهتزاز
  void _stopAlertSound() {
    _isAlertPlaying = false;
    _alertTimer?.cancel();
    _alertTimer = null;
    _audioPlayer?.stop();
    _audioPlayer?.dispose();
    _audioPlayer = null;
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
            'emergency_channel_v11',
            'تنبيهات الطوارئ - Tracka',
            importance: fln.Importance.max,
            priority: fln.Priority.max,
            fullScreenIntent: true,
            ongoing: true,
            category: fln.AndroidNotificationCategory.call,
            playSound: true,
            enableVibration: true,
            vibrationPattern: Int64List.fromList([0, 500, 300, 500, 300, 500, 300, 500]),
            sound: const fln.RawResourceAndroidNotificationSound('ride_request_sound'),
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