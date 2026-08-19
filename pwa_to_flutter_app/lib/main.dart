import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
  
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' as fln;
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';

// ✅ MethodChannel للتواصل مع Native Android
const MethodChannel _nativeChannel = MethodChannel('com.tracka.app/notifications');

// ✅ Global Navigator Key for Overlay
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// أنواع إشعارات منصة السفر (الهادئة)
const _travelTypes = {'DRIVER_OFFER', 'DRIVER_SELECTED', 'NEW_CHAT_MESSAGE'};

// ✅ نوع إشعار الرحلة الفورية (الطوارئ)
const String _rideRequestType = 'RIDE_REQUEST';

// ✅ معرف القناة الثابت
const String _emergencyChannelId = 'emergency_channel_v15';
const String _emergencyChannelName = 'تنبيهات الطوارئ - تراكا';
const String _travelChannelId = 'travel_notifications';
const String _travelChannelName = 'إشعارات السفر - تراكا';

// ✅ متغيرات عالمية للصوت والاهتزاز
AudioPlayer? _globalAudioPlayer;
Timer? _globalAlertTimer;
bool _globalIsAlertPlaying = false;

// ✅ مدة الرنين بالثواني
const int _alertDurationSeconds = 30;

// ✅ مثيل الإشعارات العالمي للخلفية
final fln.FlutterLocalNotificationsPlugin _globalNotifications = fln.FlutterLocalNotificationsPlugin();

// ✅ مؤقت لمزامنة السائق
Timer? _driverSyncTimer;

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

// ✅ دالة إيقاف الصوت والاهتزاز
void stopGlobalAlertSound() {
  print('🛑 [GLOBAL] إيقاف الصوت والاهتزاز...');
  
  _globalIsAlertPlaying = false;
  
  if (_globalAlertTimer != null) {
    _globalAlertTimer!.cancel();
    _globalAlertTimer = null;
    print('⏹️ [GLOBAL] تم إلغاء المؤقت');
  }
  
  try {
    if (_globalAudioPlayer != null) {
      _globalAudioPlayer!.stop();
      _globalAudioPlayer!.dispose();
      _globalAudioPlayer = null;
      print('✅ [GLOBAL] تم إيقاف مشغل الصوت');
    }
  } catch (e) {
    print('⚠️ [GLOBAL] خطأ في إيقاف مشغل الصوت: $e');
  }
  
  try {
    Vibration.cancel();
    print('📳 [GLOBAL] تم إلغاء الاهتزاز');
  } catch (e) {
    print('⚠️ [GLOBAL] خطأ في إلغاء الاهتزاز: $e');
  }
  
  print('✅ [GLOBAL] تم إيقاف الصوت والاهتزاز');
}

// ✅ دالة تشغيل الصوت في الخلفية
void _playAlertSoundInBackground() {
  _globalIsAlertPlaying = true;
  _vibratePhoneBackground();

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
  
  // ✅ إيقاف تلقائي بعد 30 ثانية
  Future.delayed(Duration(seconds: _alertDurationSeconds), () {
    print('⏰ انتهت مدة الرنين (${_alertDurationSeconds} ثانية) - إيقاف تلقائي');
    stopGlobalAlertSound();
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

// ✅ دالة إنشاء قنوات الإشعارات
Future<void> _createNotificationChannels(fln.AndroidFlutterLocalNotificationsPlugin? androidImpl) async {
  if (androidImpl == null) return;

  try {
    for (int i = 10; i <= 20; i++) {
      try {
        await androidImpl.deleteNotificationChannel('emergency_channel_v$i');
        await androidImpl.deleteNotificationChannel('emergency_channel_backup_v$i');
      } catch (_) {}
    }

    final emergencyChan = fln.AndroidNotificationChannel(
      _emergencyChannelId,
      _emergencyChannelName,
      description: 'قناة الطوارئ للرحلات الجديدة - صوت عالٍ واهتزاز قوي',
      importance: fln.Importance.max,
      playSound: true,
      enableVibration: true,
      audioAttributesUsage: fln.AudioAttributesUsage.notificationRingtone,
      sound: const fln.RawResourceAndroidNotificationSound('ride_request_sound'),
    );
    await androidImpl.createNotificationChannel(emergencyChan);

    const travelChan = fln.AndroidNotificationChannel(
      _travelChannelId,
      _travelChannelName,
      description: 'إشعارات قبول الرحلات والمحادثات',
      importance: fln.Importance.high,
      playSound: true,
      enableVibration: true,
    );
    await androidImpl.createNotificationChannel(travelChan);

    const serviceChan = fln.AndroidNotificationChannel(
      'foreground_service',
      'خدمة تراكا تعمل حالياً',
      description: 'إشعارات خدمة الخلفية',
      importance: fln.Importance.low,
      playSound: false,
      enableVibration: false,
    );
    await androidImpl.createNotificationChannel(serviceChan);

    print('✅ [Flutter] All notification channels created successfully');
  } catch (e) {
    print('❌ [Flutter] Error creating channels: $e');
  }
}

// ✅ دالة إلغاء جميع الإشعارات
void _cancelAllNotifications() {
  try {
    _nativeChannel.invokeMethod('cancelAllNotifications');
    print('✅ [Flutter] Native notifications cancelled');
  } catch (e) {
    print('⚠️ [Flutter] Error cancelling native notifications: $e');
  }
  try {
    _globalNotifications.cancelAll();
    print('✅ [Flutter] Local notifications cancelled');
  } catch (e) {
    print('⚠️ [Flutter] Error cancelling local notifications: $e');
  }
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  Map<String, dynamic> data = message.data;
  final String notifType = data['type']?.toString() ?? '';
  final bool isRideRequest = (notifType == _rideRequestType);

  print('📱 [Background] Received message type: $notifType');

  // ✅ RIDE_REQUEST: فقط صوت واهتزاز، لا ننشئ إشعار Flutter
  if (isRideRequest) {
    String? rideId = _extractRideId(data);
    if (await _isDuplicateRide(rideId)) {
      print('📱 [Background] Duplicate ride ignored');
      return;
    }
    _playAlertSoundInBackground();
    print('📱 [Background] RIDE_REQUEST - Sound played');
    return;
  }

  // ✅ الإشعارات الأخرى
  const androidInit = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
  await _globalNotifications.initialize(const fln.InitializationSettings(android: androidInit));

  final androidImpl = _globalNotifications.resolvePlatformSpecificImplementation<fln.AndroidFlutterLocalNotificationsPlugin>();
  if (androidImpl != null) {
    await _createNotificationChannels(androidImpl);
  }

  final bool isTravelNotif = _travelTypes.contains(notifType);
  if (isTravelNotif) {
    String title = message.notification?.title ?? 'تراكا';
    String body = message.notification?.body ?? 'لديك إشعار جديد';
    await _globalNotifications.show(
      DateTime.now().millisecond,
      title,
      body,
      fln.NotificationDetails(
        android: fln.AndroidNotificationDetails(
          _travelChannelId,
          _travelChannelName,
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
    print('📱 [Background] Travel notification shown');
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
  print('✅ Firebase initialized');

  const androidInit = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
  await _globalNotifications.initialize(
    const fln.InitializationSettings(android: androidInit),
  );

  final androidImpl = _globalNotifications.resolvePlatformSpecificImplementation<fln.AndroidFlutterLocalNotificationsPlugin>();
  if (androidImpl != null) {
    await _createNotificationChannels(androidImpl);
  }

  try {
    print('🔍 [Flutter] Requesting permissions on startup...');
    
    if (defaultTargetPlatform == TargetPlatform.android) {
      final notificationStatus = await Permission.notification.request();
      print('📱 [Flutter] Notification permission status: $notificationStatus');
      
      if (notificationStatus.isPermanentlyDenied) {
        print('⚠️ [Flutter] Notification permission permanently denied - opening settings');
        await openAppSettings();
      }
      
      if (!notificationStatus.isGranted) {
        final retryStatus = await Permission.notification.request();
        print('📱 [Flutter] Notification permission after retry: $retryStatus');
      }
    }
    
    await [
      Permission.location,
      Permission.camera,
      Permission.ignoreBatteryOptimizations,
    ].request();

    if (await Permission.location.isGranted) {
      print('🔍 [Flutter] Requesting background location permission...');
      await Permission.locationAlways.request();
    }
    
    print('✅ [Flutter] Permissions sequence processed successfully');
  } catch (e) {
    print('❌ [Flutter] Error requesting permissions on startup: $e');
  }

  try {
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null && token.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fcm_token', token);
      print('✅ [Flutter] Initial token stored: ${token.substring(0, 20)}...');
    } else {
      print('⚠️ [Flutter] No initial token available');
    }
  } catch (e) {
    print('❌ [Flutter] Error getting initial token: $e');
  }

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

  _initForegroundTask();
  runApp(const DriverApp());
}

void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'foreground_service',
      channelName: 'خدمة تراكا تعمل حالياً',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
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
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      home: const DriverHome(),
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
  String? _pendingUrl;
  RealtimeChannel? channel;
  Timer? statusSyncTimer;
  StreamSubscription<ConnectivityResult>? connectivitySubscription;
  
  OverlayEntry? _overlayEntry;

  // ✅ دالة لعرض رسالة على الشاشة
  void _showDebugMessage(String message, {bool isError = false}) {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontSize: 14),
        ),
        backgroundColor: isError ? Colors.red.shade700 : Colors.green.shade700,
        duration: const Duration(seconds: 6),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
    print('📱 [Flutter] Debug: $message');
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showDebugMessage('🚀 التطبيق جاهز');
    });

    // ✅ استماع لفتح الإشعار من Native
    _nativeChannel.setMethodCallHandler((call) async {
      print('📱 [Flutter] MethodChannel call received: ${call.method}');
      
      if (call.method == 'onNotificationOpened') {
        final payload = call.arguments as String;
        print('📱 [Flutter] Notification opened from Native: $payload');
        _showDebugMessage('📱 تم فتح الإشعار من Native');
        
        try {
          final data = jsonDecode(payload);
          print('📱 [Flutter] Parsed data: $data');
          await _handleNotificationClick(data);
        } catch (e) {
          print('❌ Error parsing notification payload: $e');
          _showDebugMessage('❌ خطأ في تحليل البيانات: $e', isError: true);
        }
      }
    });

    _initFirebaseMessaging();
    _restoreDriver();
    _initConnectivity();
    
    // ✅ التحقق من الإشعارات المعلقة (للـ Cold Start)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingNotification();
    });
  }

  @override
  void dispose() {
    stopGlobalAlertSound();
    _overlayEntry?.remove();
    _overlayEntry = null;
    statusSyncTimer?.cancel();
    _driverSyncTimer?.cancel();
    connectivitySubscription?.cancel();
    _globalAudioPlayer?.dispose();
    super.dispose();
  }

  // ✅ التحقق من الإشعارات المعلقة
  Future<void> _checkPendingNotification() async {
    try {
      print('📱 [Flutter] Checking for pending notification...');
      
      final String? payload = await _nativeChannel.invokeMethod('getPendingNotification');
      if (payload != null && payload.isNotEmpty) {
        print('📱 [Flutter] ✅ Pending notification found: $payload');
        _showDebugMessage('✅ تم العثور على إشعار معلق');
        
        try {
          final data = jsonDecode(payload);
          await _handleNotificationClick(data);
        } catch (e) {
          print('❌ Error parsing pending notification: $e');
        }
      } else {
        print('📱 [Flutter] No pending notification');
      }
    } catch (e) {
      print('⚠️ Error checking pending notification: $e');
    }
  }

  Future<void> _initFirebaseMessaging() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    
    NotificationSettings settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    
    print('📱 [Flutter] FCM Permission status: ${settings.authorizationStatus}');

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      print('⚠️ [Flutter] Notification permission denied, opening settings...');
      if (defaultTargetPlatform == TargetPlatform.android) {
        await openAppSettings();
      }
    }
    
    await messaging.setForegroundNotificationPresentationOptions(
      alert: false,
      badge: false,
      sound: false,
    );
    
    try {
      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('fcm_token', token);
        print('✅ [Flutter] FCM Token stored');
      }
    } catch (e) {
      print('❌ [Flutter] Error getting token: $e');
    }
    
    messaging.onTokenRefresh.listen((newToken) async {
      print('🔄 [Flutter] FCM Token refreshed');
      
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fcm_token', newToken);
      
      if (_isPageLoaded && web != null) {
        try {
          await web!.evaluateJavascript(
            source: "if(window.onNativeTokenChanged) window.onNativeTokenChanged('$newToken');"
          );
        } catch (e) {
          print('⚠️ [Flutter] Could not send token refresh to PWA: $e');
        }
      }
    });
    
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      print('📱 [Flutter] App opened from notification (FCM)');
      _showDebugMessage('📱 فتح من الإشعار (FCM)');
      stopGlobalAlertSound();
      _overlayEntry?.remove();
      _overlayEntry = null;
      _handleNotificationClick(message.data);
    });
    
    messaging.getInitialMessage().then((message) { 
      if (message != null) {
        print('📱 [Flutter] App opened from terminated state (FCM)');
        _showDebugMessage('📱 فتح من الإشعار (مغلق)');
        stopGlobalAlertSound();
        _overlayEntry?.remove();
        _overlayEntry = null;
        _handleNotificationClick(message.data); 
      }
    });
    
    FirebaseMessaging.onMessage.listen((message) {
      print('📱 [Flutter] Message received in foreground');
      _handleFcmMessage(message);
    });
  }

  // ✅ الدالة الأساسية لمعالجة الضغط على الإشعار
  Future<void> _handleNotificationClick(Map<String, dynamic> data) async {
    print('📱 [Flutter] ========== HANDLE NOTIFICATION CLICK ==========');
    print('📱 [Flutter] Data: $data');
    
    _showDebugMessage('📱 تم فتح الإشعار');
    
    final String notifType = data['type']?.toString() ?? '';
    final bool isTravelNotif = _travelTypes.contains(notifType);

    stopGlobalAlertSound();
    _overlayEntry?.remove();
    _overlayEntry = null;

    // ✅ إشعارات السفر العادية
    if (isTravelNotif) {
      _showDebugMessage('📱 فتح منصة السفر');
      const String travelUrl = 'https://tracka.zoonasd.com/driver_app/travel-platform.html';
      if (web != null && _isPageLoaded) {
        await web!.loadUrl(urlRequest: URLRequest(url: WebUri(travelUrl)));
      } else {
        setState(() => _pendingUrl = travelUrl);
        _showDebugMessage('⏳ WebView غير جاهز، سيتم فتحه لاحقاً');
      }
      return;
    }

    // ✅ استخراج ride_id
    String? rideId = _extractRideId(data);
    
    if (rideId == null || rideId.isEmpty) {
      print('❌ [Flutter] No rideId found');
      _showDebugMessage('⚠️ لا يوجد rideId', isError: true);
      return;
    }

    // ✅ بناء الرابط
    final url = "https://tracka.zoonasd.com/driver_app/accept-ride.html?ride_id=$rideId";
    print('📱 [Flutter] ✅ Opening URL: $url');
    _showDebugMessage('✅ فتح الرحلة ID: $rideId');
    
    // ✅ تحميل الرابط في WebView
    if (web != null && _isPageLoaded) {
      try {
        await web!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
        _showDebugMessage('🌐 جارٍ فتح صفحة القبول...');
      } catch (e) {
        print('❌ [Flutter] Error loading URL: $e');
        _showDebugMessage('❌ خطأ في تحميل الصفحة: $e', isError: true);
        setState(() => _pendingUrl = url);
      }
    } else {
      print('📱 [Flutter] WebView not ready - setting pending URL');
      setState(() => _pendingUrl = url);
      _showDebugMessage('⏳ WebView غير جاهز، سيتم فتحه لاحقاً');
    }
    
    print('📱 [Flutter] ===============================================');
  }

  void _handleFcmMessage(RemoteMessage message) async {
    Map<String, dynamic> data = Map<String, dynamic>.from(message.data);
    final String notifType = data['type']?.toString() ?? '';
    final bool isTravelNotif = _travelTypes.contains(notifType);
    final bool isRideRequest = (notifType == _rideRequestType);

    print('📱 [Foreground] Message type: $notifType');

    if (isTravelNotif) {
      await _showTravelNotification(data, message.notification?.title, message.notification?.body);
      return;
    }

    if (isRideRequest) {
      String? rideId = _extractRideId(data);
      if (await _isDuplicateRide(rideId)) {
        print('📱 [Foreground] Duplicate ride ignored');
        return;
      }

      print('📱 [Foreground] 🚨 RIDE_REQUEST received!');
      _showDebugMessage('🚨 تم استلام طلب رحلة جديد!');

      stopGlobalAlertSound();
      _playAlertSound();
      
      await _showLocalNotification(data);
      _showRideRequestModal(data);
      await _sendToPWA(data);
      
      return;
    }

    await _showTravelNotification(data, message.notification?.title, message.notification?.body);
  }

  Future<void> _restoreDriver() async {
    final prefs = await SharedPreferences.getInstance();
    driverId = prefs.getString('driver_id');
    final lastUrl = prefs.getString('last_url');
    if (_pendingUrl == null && lastUrl != null && lastUrl.isNotEmpty) {
      if (web != null) {
        await web!.loadUrl(urlRequest: URLRequest(url: WebUri(lastUrl)));
      } else {
        setState(() => _pendingUrl = lastUrl);
      }
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

          print('📱 [Supabase] 🚨 New ride request inserted!');
          _showDebugMessage('🚨 طلب رحلة جديد من Supabase!');

          _playAlertSound();
          await _showLocalNotification(rideData);
          _showRideRequestModal(rideData);
          await _sendToPWA(rideData);
        },
      )..subscribe();
  }

  void _playAlertSound() {
    stopGlobalAlertSound();
    _globalIsAlertPlaying = true;
    _vibratePhone();

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

    Future.delayed(const Duration(seconds: _alertDurationSeconds), () {
      print('⏰ انتهت مدة الرنين (${_alertDurationSeconds} ثانية) - إيقاف تلقائي');
      stopGlobalAlertSound();
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

  void _stopAlerts() {
    print('🛑 إيقاف جميع التنبيهات...');
    _showDebugMessage('🛑 إيقاف التنبيهات');
    stopGlobalAlertSound();
    
    if (_overlayEntry != null) {
      _overlayEntry!.remove();
      _overlayEntry = null;
    }
    
    _cancelAllNotifications();
  }

  Future<void> _showLocalNotification(Map<String, dynamic> data) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final status = await Permission.notification.status;
        if (!status.isGranted) {
          print('⚠️ [Flutter] Notification permission not granted');
          final newStatus = await Permission.notification.request();
          if (!newStatus.isGranted) {
            print('❌ [Flutter] Notification permission denied');
            return;
          }
        }
      }

      final String title = '🚨 طلب رحلة جديد';
      final String body = '${data['customer_name'] ?? 'عميل'} - ${data['amount'] ?? 0} SDG';
      final String payload = jsonEncode(data);

      print('📱 [Flutter] Showing notification via Native');
      _showDebugMessage('📱 عرض إشعار عبر Native');

      await _nativeChannel.invokeMethod('showEmergencyNotification', {
        'title': title,
        'body': body,
        'payload': payload,
      });

      print('✅ [Flutter] Notification shown via Native');
      _showDebugMessage('✅ تم عرض الإشعار');
    } catch (e) {
      print('❌ Error showing notification via Native: $e');
      _showDebugMessage('❌ خطأ في عرض الإشعار: $e', isError: true);
      try {
        await _showLocalNotificationFallback(data);
      } catch (fallbackError) {
        print('❌ Fallback notification also failed: $fallbackError');
      }
    }
  }

  Future<void> _showLocalNotificationFallback(Map<String, dynamic> data) async {
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
            autoCancel: false,
            playSound: true,
            enableVibration: true,
            additionalFlags: Int32List.fromList([4]),
            vibrationPattern: Int64List.fromList([0, 500, 300, 500, 300, 500, 300, 500, 300, 500, 300, 500]),
            sound: const fln.RawResourceAndroidNotificationSound('ride_request_sound'),
            channelShowBadge: true,
            visibility: fln.NotificationVisibility.public,
            timeoutAfter: 30000,
            styleInformation: const fln.BigTextStyleInformation(''),
          ),
        ),
        payload: jsonEncode(data),
      );

      print('✅ [Flutter] Fallback notification shown successfully');
      _showDebugMessage('✅ تم عرض Fallback بنجاح');
    } catch (e) {
      print('❌ Fallback notification error: $e');
      rethrow;
    }
  }

  Future<void> _showTravelNotification(Map<String, dynamic> data, String? title, String? body) async {
    try {
      final String finalTitle = title ?? 'تراكا';
      final String finalBody = body ?? 'لديك إشعار جديد';
      await notifications.show(
        DateTime.now().millisecond,
        finalTitle,
        finalBody,
        fln.NotificationDetails(
          android: fln.AndroidNotificationDetails(
            _travelChannelId,
            _travelChannelName,
            importance: fln.Importance.high,
            priority: fln.Priority.high,
            playSound: true,
            enableVibration: true,
          ),
        ),
        payload: jsonEncode(data),
      );
      print('✅ [Flutter] Travel notification shown');
      _showDebugMessage('✅ تم عرض إشعار السفر');
    } catch (e) {
      print('❌ Error showing travel notification: $e');
    }
  }

  void _showRideRequestModal(Map<String, dynamic> data) {
    _overlayEntry?.remove();
    
    final context = navigatorKey.currentContext;
    if (context == null) return;
    
    _overlayEntry = OverlayEntry(
      builder: (context) => Material(
        color: Colors.black54,
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 20,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '🚨 طلب رحلة جديد',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const Divider(),
                const SizedBox(height: 8),
                Text(
                  data['customer_name'] ?? 'عميل',
                  style: const TextStyle(fontSize: 18),
                ),
                const SizedBox(height: 4),
                Text(
                  '${data['amount'] ?? 0} SDG',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.green,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                      ),
                      onPressed: () {
                        _acceptRide(data);
                      },
                      child: const Text(
                        'قبول',
                        style: TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ),
                    const SizedBox(width: 16),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                      ),
                      onPressed: () {
                        _rejectRide();
                      },
                      child: const Text(
                        'تجاهل',
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  Future<void> _acceptRide(Map<String, dynamic> data) async {
    print('✅ قبول الرحلة - إيقاف التنبيهات...');
    _showDebugMessage('✅ قبول الرحلة');
    _stopAlerts();
    
    try { 
      await supabase.from('ride_requests').update({'status': 'accepted'}).eq('ride_id', data['ride_id'] ?? data['rideId']).eq('driver_id', driverId!); 
    } catch (_) {}
    
    final rideId = _extractRideId(data);
    if (rideId != null && web != null) {
      final url = "https://tracka.zoonasd.com/driver_app/accept-ride.html?ride_id=$rideId";
      await web!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
      _showDebugMessage('🌐 فتح صفحة القبول');
    }
  }

  void _rejectRide() {
    print('❌ رفض الرحلة - إيقاف التنبيهات...');
    _showDebugMessage('❌ رفض الرحلة');
    _stopAlerts();
  }

  Future<void> _sendToPWA(Map<String, dynamic> data) async {
    if (web == null) return;
    try {
      await web!.evaluateJavascript(source: "if(typeof handleRideRequest === 'function') handleRideRequest(${jsonEncode(data)});");
    } catch (e) {
      print('⚠️ Error sending to PWA: $e');
    }
  }

  void _notifyPWAOfDriver(String id) { 
    if (web == null) return; 
    web!.evaluateJavascript(source: "localStorage.setItem('driver_id', '$id');"); 
  }

  void _startStatusSyncWithPWA() {
    statusSyncTimer?.cancel();
    statusSyncTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (web == null || driverId == null) return;
      try {
        final res = await web!.evaluateJavascript(source: "localStorage.getItem('driver_forever_online')");
        if (res != null) _updateDriverStatusInSupabase(res == 'true');
      } catch (_) {}
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

  void _startDriverSync() {
    _driverSyncTimer?.cancel();
    
    _driverSyncTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (web == null) return;
      try {
        final res = await web!.evaluateJavascript(source: "localStorage.getItem('driver_id')");
        if (res != null && res != 'null' && res != driverId) {
          print('📱 [Flutter] 🔄 Driver ID changed to: $res');
          _saveDriver(res);
        }
      } catch (_) {}
    });
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
              
              print('📱 [Flutter] 🚀 WebView Created');
              
              // ✅ إذا كان هناك رابط معلق، حمله فوراً
              if (_pendingUrl != null) {
                final url = _pendingUrl!;
                _pendingUrl = null;
                print('📱 [Flutter] Loading pending URL: $url');
                _showDebugMessage('🌐 تحميل الرابط المعلق: $url');
                controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
              }
              
              // ✅ تسجيل الـ Handlers
              controller.addJavaScriptHandler(
                handlerName: 'ping',
                callback: (args) {
                  print('📱 [Flutter] ✅ Ping received from PWA');
                  return 'pong';
                },
              );
              
              controller.addJavaScriptHandler(
                handlerName: 'getFCMToken',
                callback: (args) async {
                  print('📱 [Flutter] 📞 getFCMToken called from PWA');
                  try {
                    NotificationSettings settings = await FirebaseMessaging.instance.requestPermission(
                      alert: true,
                      badge: true,
                      sound: true,
                    );
                    
                    if (settings.authorizationStatus != AuthorizationStatus.authorized) {
                      return null;
                    }
                    
                    String? token;
                    for (int i = 0; i < 3; i++) {
                      try {
                        token = await FirebaseMessaging.instance.getToken();
                        if (token != null && token.isNotEmpty) break;
                      } catch (e) {
                        print('📱 [Flutter] ❌ Attempt ${i+1} failed: $e');
                      }
                      await Future.delayed(Duration(seconds: 1));
                    }
                    
                    if (token != null && token.isNotEmpty) {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString('fcm_token', token);
                      return token;
                    }
                    return null;
                  } catch (e) {
                    print('📱 [Flutter] ❌ Error: $e');
                    return null;
                  }
                },
              );
              
              controller.addJavaScriptHandler(
                handlerName: 'getStoredFCMToken',
                callback: (args) async {
                  print('📱 [Flutter] 📞 getStoredFCMToken called');
                  try {
                    final prefs = await SharedPreferences.getInstance();
                    final token = prefs.getString('fcm_token');
                    return token;
                  } catch (e) {
                    return null;
                  }
                },
              );
              
              controller.addJavaScriptHandler(
                handlerName: 'checkFCMStatus',
                callback: (args) async {
                  print('📱 [Flutter] 🔍 checkFCMStatus called');
                  try {
                    final token = await FirebaseMessaging.instance.getToken();
                    final settings = await FirebaseMessaging.instance.requestPermission();
                    return {
                      'hasToken': token != null && token.isNotEmpty,
                      'token': token,
                      'permission': settings.authorizationStatus.toString(),
                      'tokenLength': token?.length ?? 0,
                    };
                  } catch (e) {
                    return {'error': e.toString(), 'hasToken': false};
                  }
                },
              );
              
              controller.addJavaScriptHandler(
                handlerName: 'tokenSyncComplete',
                callback: (args) {
                  print('📱 [Flutter] ✅ PWA confirmed token sync: $args');
                  return 'OK';
                },
              );
              
              controller.addJavaScriptHandler(
                handlerName: 'stopAlertsFromPWA', 
                callback: (args) { 
                  print('📱 [Flutter] 🛑 Stop alerts received from PWA');
                  _stopAlerts(); 
                  return 'OK';
                }
              );
              
              controller.addJavaScriptHandler(
                handlerName: 'stopAlerts', 
                callback: (args) { 
                  print('📱 [Flutter] 🛑 Stop alerts (alt) received from PWA');
                  _stopAlerts();
                  return 'OK';
                }
              );
              
              controller.addJavaScriptHandler(
                handlerName: 'driverLogin', 
                callback: (args) { 
                  print('📱 [Flutter] 🔐 Driver login received from PWA');
                  
                  if (args.isNotEmpty && args[0] is Map) {
                    final data = args[0] as Map;
                    final id = data['id']?.toString() ?? data['driver_id']?.toString();
                    if (id != null && id.isNotEmpty) {
                      print('📱 [Flutter] ✅ Driver ID: $id');
                      _saveDriver(id);
                    }
                  }
                  return 'OK';
                }
              );
              
              controller.addJavaScriptHandler(
                handlerName: 'getDriverId',
                callback: (args) {
                  print('📱 [Flutter] 📞 getDriverId called from PWA');
                  return driverId ?? '';
                },
              );
              
              print('📱 [Flutter] ✅ All Handlers Registered Successfully');
            },
            onGeolocationPermissionsShowPrompt: (controller, origin) async => 
                GeolocationPermissionShowPromptResponse(origin: origin, allow: true, retain: true),
            onLoadStop: (controller, url) async {
              _isPageLoaded = true;
              print('📱 [Flutter] 🌐 Page loaded: $url');
              
              if (url != null) {
                final String currentUrl = url.toString();
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('last_url', currentUrl);

                if (currentUrl.contains('accept-ride.html')) {
                  print('📱 [Flutter] 📍 accept-ride.html loaded - stopping alerts');
                  _showDebugMessage('📍 تم فتح صفحة القبول');
                  _stopAlerts();
                }
              }
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
}