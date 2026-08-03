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
import 'package:http/http.dart' as http;

// ✅ Global Navigator Key for Overlay
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// أنواع إشعارات منصة السفر (الهادئة)
const _travelTypes = {'DRIVER_OFFER', 'DRIVER_SELECTED', 'NEW_CHAT_MESSAGE'};

// ✅ نوع إشعار الرحلة الفورية (الطوارئ)
const String _rideRequestType = 'RIDE_REQUEST';

// ✅ معرف القناة الثابت
const String _emergencyChannelId = 'emergency_channel_v11';
const String _emergencyChannelName = 'تنبيهات الطوارئ - تراكا';

// ✅ متغيرات عالمية للصوت والاهتزاز
AudioPlayer? _globalAudioPlayer;
Timer? _globalAlertTimer;
bool _globalIsAlertPlaying = false;

// ✅ مدة الرنين بالثواني
const int _alertDurationSeconds = 30;

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
  print(' [GLOBAL] إيقاف الصوت والاهتزاز...');

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
    print(' [GLOBAL] تم إلغاء الاهتزاز');
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

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  Map<String, dynamic> data = message.data;
  final String notifType = data['type']?.toString() ?? '';
  final bool isTravelNotif = _travelTypes.contains(notifType);
  final bool isRideRequest = (notifType == _rideRequestType);

  if (isRideRequest) {
    String? rideId = _extractRideId(data);
    if (await _isDuplicateRide(rideId)) return;
    _playAlertSoundInBackground();
  }

  final fln.FlutterLocalNotificationsPlugin notifications = fln.FlutterLocalNotificationsPlugin();
  const android = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
  await notifications.initialize(const fln.InitializationSettings(android: android));

  String title = message.notification?.title ?? (isTravelNotif ? 'تراكا' : ' طلب رحلة جديد');
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
  } else if (isRideRequest) {
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
          fullScreenIntent: true,
          category: fln.AndroidNotificationCategory.call,
          playSound: true,
          enableVibration: true,
          additionalFlags: Int32List.fromList([4]),
          vibrationPattern: Int64List.fromList([0, 500, 300, 500, 300, 500, 300, 500, 300, 500, 300, 500]),
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
  
  // ✅ Flutter هو المالك الوحيد لهذه البيانات
  String? driverId;
  String? fcmToken;
  String? _pendingUrl;
  
  RealtimeChannel? channel;
  Timer? statusSyncTimer;
  StreamSubscription<ConnectivityResult>? connectivitySubscription;

  // ✅ Overlay entry for persistent modal
  OverlayEntry? _overlayEntry;

  // ✅ مؤقت لمزامنة التوكن مع الخادم
  Timer? _tokenSyncRetryTimer;
  int _tokenSyncAttempts = 0;
  static const int _maxTokenSyncAttempts = 30;

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
    stopGlobalAlertSound();
    _overlayEntry?.remove();
    _overlayEntry = null;
    statusSyncTimer?.cancel();
    connectivitySubscription?.cancel();
    _tokenSyncRetryTimer?.cancel();
    _globalAudioPlayer?.dispose();
    super.dispose();
  }

  // ============================================================
  // 1. إدارة التوكن - Flutter هو المصدر الوحيد
  // ============================================================

  // ✅ الحصول على التوكن وحفظه محلياً
  Future<void> _initFirebaseMessaging() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);

    await messaging.setForegroundNotificationPresentationOptions(
      alert: false,
      badge: false,
      sound: false,
    );

    // ✅ الحصول على التوكن وحفظه فوراً
    try {
      fcmToken = await messaging.getToken();
      if (fcmToken != null && _isValidFcmTokenFormat(fcmToken!)) {
        await _saveTokenLocally(fcmToken!);
        print('✅ [FCM] تم حفظ التوكن محلياً: ${fcmToken!.substring(0, 20)}...');
        
        // ✅ إذا كان المستخدم معروفاً، أرسل التوكن للخادم
        if (driverId != null) {
          await _sendTokenToServer(fcmToken!);
        }
      }
    } catch (e) {
      print('❌ [FCM] خطأ في الحصول على التوكن: $e');
    }

    // ✅ مراقبة تحديثات التوكن
    messaging.onTokenRefresh.listen((newToken) async {
      print('🔄 [FCM] تم تحديث التوكن');
      fcmToken = newToken;
      await _saveTokenLocally(newToken);
      
      // ✅ إذا كان المستخدم معروفاً، أرسل التوكن الجديد للخادم
      if (driverId != null) {
        await _sendTokenToServer(newToken);
        _sendTokenToPWA(newToken);
      }
    });

    // ✅ معالجة الرسائل
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      stopGlobalAlertSound();
      _overlayEntry?.remove();
      _overlayEntry = null;
      _handleNotificationClick(message.data);
    });

    messaging.getInitialMessage().then((message) {
      if (message != null) {
        stopGlobalAlertSound();
        _overlayEntry?.remove();
        _overlayEntry = null;
        _handleNotificationClick(message.data);
      }
    });

    FirebaseMessaging.onMessage.listen((message) {
      _handleFcmMessage(message);
    });
  }

  // ✅ حفظ التوكن في SharedPreferences
  Future<void> _saveTokenLocally(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fcm_token_cached', token);
    await prefs.setInt('fcm_token_cached_at', DateTime.now().millisecondsSinceEpoch);
  }

  // ✅ استعادة التوكن من SharedPreferences
  Future<String?> _getTokenLocally() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('fcm_token_cached');
  }

  // ✅ التحقق من صحة التوكن
  bool _isValidFcmTokenFormat(String token) {
    if (token.isEmpty) return false;
    if (token == 'false' || token == 'null') return false;
    if (token.length < 50) return false;
    return true;
  }

  // ✅ إرسال التوكن إلى الخادم مع userId
  Future<void> _sendTokenToServer(String token) async {
    final currentDriverId = driverId;
    if (currentDriverId == null) {
      print('⏳ [FCM] لا يوجد userId، سيتم الإرسال لاحقاً');
      return;
    }

    if (!_isValidFcmTokenFormat(token)) {
      print('⚠️ [FCM] توكن غير صالح');
      return;
    }

    try {
      // ✅ تحديث في Supabase
      final response = await supabase
          .from('drivers')
          .update({
            'fcm_token': token,
            'fcm_token_updated_at': DateTime.now().toIso8601String(),
            'fcm_token_valid': true,
          })
          .eq('id', currentDriverId)
          .select();

      if (response != null && response.isNotEmpty) {
        print('✅ [FCM] تم ربط التوكن بالمستخدم $currentDriverId');
        
        // ✅ إرسال إلى PWA
        _sendTokenToPWA(token);
        
        // ✅ حفظ حالة المزامنة
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('fcm_token_synced_driver_id', currentDriverId);
        await prefs.setString('fcm_token_synced_value', token);
      }
    } catch (e) {
      print('❌ [FCM] خطأ في إرسال التوكن للخادم: $e');
    }
  }

  // ============================================================
  // 2. التواصل مع PWA عبر JavaScript Bridge
  // ============================================================

  // ✅ إرسال التوكن إلى PWA (عند الطلب)
  void _sendTokenToPWA(String token) async {
    if (web == null) return;
    try {
      await web!.evaluateJavascript(source: """
        (function() {
          if (typeof window.onFcmTokenReceived === 'function') {
            window.onFcmTokenReceived('$token', '${driverId ?? ''}');
            console.log('✅ [PWA] تم استلام التوكن من Flutter');
          } else {
            console.log('⏳ [PWA] window.onFcmTokenReceived غير معرف، سيتم التخزين مؤقتاً');
            localStorage.setItem('flutter_fcm_token', '$token');
            localStorage.setItem('flutter_driver_id', '${driverId ?? ''}');
          }
        })();
      """);
    } catch (e) {
      print('⚠️ [PWA] خطأ في إرسال التوكن: $e');
    }
  }

  // ✅ طلب التوكن من PWA (عند تحميل الصفحة)
  void _requestTokenFromPWA() async {
    if (web == null) return;
    try {
      await web!.evaluateJavascript(source: """
        (function() {
          if (typeof window.requestFcmToken === 'function') {
            console.log('📨 [PWA] طلب التوكن من Flutter...');
            window.requestFcmToken();
          } else {
            console.log('⚠️ [PWA] window.requestFcmToken غير معرف');
          }
        })();
      """);
    } catch (e) {
      print('⚠️ [PWA] خطأ في طلب التوكن: $e');
    }
  }

  // ============================================================
  // 3. استقبال userId من PWA
  // ============================================================

  // ✅ استقبال userId من PWA وربطه بالتوكن
  Future<void> _onUserLoggedIn(String userId) async {
    print('👤 [PWA] تم استقبال userId: $userId');
    
    final prefs = await SharedPreferences.getInstance();
    driverId = userId;
    await prefs.setString('driver_id', userId);
    
    // ✅ الحصول على التوكن المخزن
    final token = fcmToken ?? await _getTokenLocally();
    
    if (token != null && _isValidFcmTokenFormat(token)) {
      print('🔄 [FCM] ربط التوكن بالمستخدم $userId');
      fcmToken = token;
      await _sendTokenToServer(token);
    } else {
      print('⚠️ [FCM] لا يوجد توكن صالح للربط');
      // ✅ طلب توكن جديد من FCM
      try {
        final messaging = FirebaseMessaging.instance;
        final newToken = await messaging.getToken();
        if (newToken != null) {
          fcmToken = newToken;
          await _saveTokenLocally(newToken);
          await _sendTokenToServer(newToken);
        }
      } catch (e) {
        print('❌ [FCM] خطأ في الحصول على توكن جديد: $e');
      }
    }
    
    // ✅ بدء الاستماع للرحلات
    _listenForRides();
    _startStatusSyncWithPWA();
    _startForegroundService();
    
    // ✅ إرسال التوكن إلى PWA
    if (fcmToken != null) {
      _sendTokenToPWA(fcmToken!);
    }
  }

  // ============================================================
  // 4. استعادة الجلسة
  // ============================================================

  Future<void> _restoreDriver() async {
    final prefs = await SharedPreferences.getInstance();
    final savedDriverId = prefs.getString('driver_id');
    final lastUrl = prefs.getString('last_url');

    // ✅ استعادة التوكن
    final cachedToken = await _getTokenLocally();
    if (cachedToken != null && _isValidFcmTokenFormat(cachedToken)) {
      fcmToken = cachedToken;
      print('♻️ [FCM] تم استعادة التوكن من التخزين المحلي');
    }

    // ✅ استعادة userId
    if (savedDriverId != null) {
      driverId = savedDriverId;
      print('♻️ [DRIVER] استعادة userId: $savedDriverId');
      
      // ✅ ربط التوكن بالمستخدم
      if (fcmToken != null) {
        await _sendTokenToServer(fcmToken!);
      }
      
      _listenForRides();
      _startStatusSyncWithPWA();
      _startForegroundService();
    }

    // ✅ استعادة URL
    if (_pendingUrl == null && lastUrl != null && lastUrl.isNotEmpty) {
      if (web != null) {
        web!.loadUrl(urlRequest: URLRequest(url: WebUri(lastUrl)));
      } else {
        setState(() => _pendingUrl = lastUrl);
      }
    }
  }

  // ============================================================
  // 5. دوال التطبيق الأخرى
  // ============================================================

  Future<void> _initNotifications() async {
    const androidInit = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
    await notifications.initialize(
      const fln.InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: (details) {
        stopGlobalAlertSound();
        _overlayEntry?.remove();
        _overlayEntry = null;
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
        audioAttributesUsage: fln.AudioAttributesUsage.notificationRingtone,
        sound: const fln.RawResourceAndroidNotificationSound('ride_request_sound'),
      );
      await androidImplementation.createNotificationChannel(emergencyChan);

      // ✅ قناة إشعارات السفر
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

  void _initConnectivity() {
    connectivitySubscription = Connectivity().onConnectivityChanged.listen((result) {
      if (result != ConnectivityResult.none && driverId != null) {
        _listenForRides();
        _updateDriverStatusInSupabase(true);
      }
    });
  }

  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      notificationTitle: 'Tracka يعمل في الخلفية',
      notificationText: 'جاهز لاستقبال طلبات الرحلات',
      callback: startCallback,
    );
  }

  void _listenForRides() {
    final currentDriverId = driverId;
    if (currentDriverId == null) return;

    channel?.unsubscribe();
    channel = supabase.channel('ride_requests_$currentDriverId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'ride_requests',
        filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'driver_id', value: currentDriverId),
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
      print('⏰ انتهت مدة الرنين - إيقاف تلقائي');
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
    print(' إيقاف جميع التنبيهات...');
    stopGlobalAlertSound();

    if (_overlayEntry != null) {
      _overlayEntry!.remove();
      _overlayEntry = null;
    }

    try {
      notifications.cancelAll();
    } catch (_) {}
  }

  void _handleNotificationClick(Map<String, dynamic> data) {
    final String notifType = data['type']?.toString() ?? '';
    final bool isTravelNotif = _travelTypes.contains(notifType);

    stopGlobalAlertSound();
    _overlayEntry?.remove();
    _overlayEntry = null;

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
    final bool isRideRequest = (notifType == _rideRequestType);

    // ✅ معالجة طلب تحديث التوكن من الخادم
    if (data['type'] == 'REFRESH_TOKEN_REQUEST') {
      print('🔄 [FCM] طلب تحديث التوكن من الخادم');
      final String? requestedDriverId = data['driver_id'];
      if (requestedDriverId == driverId && fcmToken != null) {
        await _sendTokenToServer(fcmToken!);
        _sendTokenToPWA(fcmToken!);
      }
      return;
    }

    if (isTravelNotif) {
      await _showTravelNotification(data, message.notification?.title, message.notification?.body);
      return;
    }

    if (isRideRequest) {
      String? rideId = _extractRideId(data);
      if (await _isDuplicateRide(rideId)) return;

      stopGlobalAlertSound();
      _playAlertSound();

      _showRideRequestModal(data);
      await _showLocalNotification(data);
      await _sendToPWA(data);

      return;
    }

    await _showTravelNotification(data, message.notification?.title, message.notification?.body);
  }

  Future<void> _showLocalNotification(Map<String, dynamic> data) async {
    try {
      String name = data['customer_name'] ?? 'عميل';
      String amount = data['amount']?.toString() ?? '0';
      String? rideId = _extractRideId(data);

      await notifications.show(
        rideId?.hashCode ?? DateTime.now().millisecond,
        ' طلب رحلة جديد',
        '$name - $amount SDG',
        fln.NotificationDetails(
          android: fln.AndroidNotificationDetails(
            _emergencyChannelId,
            _emergencyChannelName,
            importance: fln.Importance.max,
            priority: fln.Priority.max,
            ongoing: true,
            fullScreenIntent: true,
            category: fln.AndroidNotificationCategory.call,
            playSound: true,
            enableVibration: true,
            additionalFlags: Int32List.fromList([4]),
            vibrationPattern: Int64List.fromList([0, 500, 300, 500, 300, 500, 300, 500, 300, 500, 300, 500]),
            sound: const fln.RawResourceAndroidNotificationSound('ride_request_sound'),
            channelShowBadge: true,
            visibility: fln.NotificationVisibility.public,
            timeoutAfter: null,
          ),
        ),
        payload: jsonEncode(data),
      );
    } catch (e) {
      print('❌ خطأ في عرض الإشعار: $e');
    }
  }

  Future<void> _showTravelNotification(Map<String, dynamic> data, String? title, String? body) async {
    try {
      final String finalTitle = title ?? 'تراكا';
      final String finalBody = body ?? 'لديك إشعار جديد';
      await notifications.show(
        DateTime.now().millisecond, finalTitle, finalBody,
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
                  ' طلب رحلة جديد',
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
    print(' قبول الرحلة - إيقاف التنبيهات...');
    _stopAlerts();

    final currentDriverId = driverId;
    if (currentDriverId == null) {
      print('⚠️ لا يوجد سائق مسجل');
      return;
    }

    try {
      await supabase
          .from('ride_requests')
          .update({'status': 'accepted'})
          .eq('ride_id', data['ride_id'] ?? data['rideId'])
          .eq('driver_id', currentDriverId);
    } catch (_) {}

    final rideId = _extractRideId(data);
    if (rideId != null && web != null) {
      final url = "https://tracka.zoonasd.com/driver_app/accept-ride.html?id=$rideId";
      await web!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
  }

  void _rejectRide() {
    print('❌ رفض الرحلة - إيقاف التنبيهات...');
    _stopAlerts();
  }

  Future<void> _sendToPWA(Map<String, dynamic> data) async {
    if (web == null) return;
    try {
      await web!.evaluateJavascript(source: "if(typeof handleRideRequest === 'function') handleRideRequest(${jsonEncode(data)});");
    } catch (_) {}
  }

  void _startStatusSyncWithPWA() {
    statusSyncTimer?.cancel();
    statusSyncTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (web == null) return;
      final currentDriverId = driverId;
      if (currentDriverId == null) return;

      try {
        final res = await web!.evaluateJavascript(source: "localStorage.getItem('driver_forever_online')");
        if (res != null) _updateDriverStatusInSupabase(res == 'true');
      } catch (_) {}
    });
  }

  Future<void> _updateDriverStatusInSupabase(bool isOnline) async {
    final currentDriverId = driverId;
    if (currentDriverId == null) return;

    try {
      await supabase.from('driver_locations').upsert({
        'driver_id': currentDriverId,
        'is_online': isOnline,
        'last_seen': DateTime.now().toIso8601String()
      }).timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  // ============================================================
  // 6. واجهة المستخدم - WebView
  // ============================================================

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

              // ✅ استقبال userId من PWA
              controller.addJavaScriptHandler(
                handlerName: 'onUserLoggedIn',
                callback: (args) {
                  if (args.isNotEmpty && args[0] is Map) {
                    final userId = args[0]['userId']?.toString();
                    if (userId != null && userId.isNotEmpty) {
                      _onUserLoggedIn(userId);
                    }
                  }
                  return 'OK';
                }
              );

              // ✅ طلب التوكن من Flutter
              controller.addJavaScriptHandler(
                handlerName: 'requestFcmToken',
                callback: (args) {
                  print('📨 [PWA] طلب التوكن من Flutter');
                  if (fcmToken != null) {
                    _sendTokenToPWA(fcmToken!);
                  } else {
                    // ✅ محاولة استعادة التوكن
                    _getTokenLocally().then((token) {
                      if (token != null) {
                        fcmToken = token;
                        _sendTokenToPWA(token);
                      }
                    });
                  }
                  return fcmToken ?? '';
                }
              );

              // ✅ إيقاف التنبيهات
              controller.addJavaScriptHandler(
                handlerName: 'stopAlerts',
                callback: (args) {
                  print(' تم استلام طلب إيقاف التنبيهات');
                  _stopAlerts();
                  return 'OK';
                }
              );

              // ✅ تسجيل الخروج
              controller.addJavaScriptHandler(
                handlerName: 'onUserLoggedOut',
                callback: (args) {
                  print('👤 [PWA] تسجيل خروج المستخدم');
                  driverId = null;
                  final prefs = SharedPreferences.getInstance();
                  prefs.then((p) => p.remove('driver_id'));
                  return 'OK';
                }
              );

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

                if (currentUrl.contains('accept-ride.html')) {
                  print(' تم تحميل accept-ride.html');
                  _stopAlerts();
                }
              }

              // ✅ بعد تحميل الصفحة، أرسل التوكن إذا كان موجوداً
              if (fcmToken != null) {
                _sendTokenToPWA(fcmToken!);
              }

              // ✅ اطلب من PWA إرسال userId إذا كان مسجلاً
              _requestTokenFromPWA();
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