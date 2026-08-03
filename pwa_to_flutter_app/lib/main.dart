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
  String? driverId;
  String? fcmToken;
  String? _pendingUrl;
  RealtimeChannel? channel;
  Timer? statusSyncTimer;
  StreamSubscription<ConnectivityResult>? connectivitySubscription;
  
  // ✅ Overlay entry for persistent modal
  OverlayEntry? _overlayEntry;

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
    _globalAudioPlayer?.dispose();
    super.dispose();
  }

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

      // ✅ إنشاء قناة الطوارئ الرئيسية (للرحلات الفورية)
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
      
      // ✅ قناة إشعارات السفر (هادئة - للرحلات العادية والمحادثات)
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

  // ✅ دالة الحصول على التوكن من Firebase (الطريقة الرسمية)
  Future<String?> _getFCMToken() async {
    try {
      // ✅ الطريقة الرسمية للحصول على التوكن
      String? token = await FirebaseMessaging.instance.getToken();
      
      if (token != null && token.isNotEmpty) {
        print('✅ FCM Token obtained: $token');
        return token;
      } else {
        print('❌ Failed to get FCM Token');
        return null;
      }
    } catch (e) {
      print('❌ Error getting FCM token: $e');
      return null;
    }
  }

  // ✅ دالة للتحقق من صلاحية التوكن
  Future<String?> _validateAndRefreshToken(String? currentToken) async {
    try {
      // ✅ الطريقة الرسمية للحصول على توكن جديد
      String? newToken = await FirebaseMessaging.instance.getToken();
      
      if (newToken == null || newToken.isEmpty) {
        return null;
      }
      
      // إذا كان التوكن الحالي مختلفاً عن الجديد، نستخدم الجديد
      if (currentToken != newToken) {
        print('🔄 Token changed: $currentToken -> $newToken');
        return newToken;
      }
      
      print('✅ Token is valid');
      return currentToken;
    } catch (e) {
      print('❌ Error validating token: $e');
      return null;
    }
  }

  // ✅ دالة لإرسال التوكن إلى PWA
  Future<void> _sendTokenToPWA(String token) async {
    if (web != null && _isPageLoaded) {
      try {
        await web!.evaluateJavascript(source: """
          // ✅ حفظ التوكن في localStorage
          localStorage.setItem('fcm_token', '$token');
          localStorage.setItem('pending_fcm_token', '$token');
          localStorage.setItem('flutter_token_ready', 'true');
          
          // ✅ تحديث التوكن في PWA
          if (typeof window.setFCMToken === 'function') {
            window.setFCMToken('$token');
          }
          
          // ✅ إرسال حدث للـ PWA
          window.dispatchEvent(new CustomEvent('flutterTokenReady', {
            detail: { token: '$token' }
          }));
          
          console.log('✅ Token sent from Flutter to PWA:', '$token');
        """);
        print('✅ Token sent to PWA: $token');
      } catch (e) {
        print('⚠️ Failed to send token to PWA: $e');
      }
    } else {
      print('⏳ WebView not ready, token will be sent later');
    }
  }

  // ✅ دالة تحديث التوكن في Supabase (مع التصحيح)
  Future<void> _updateTokenInDrivers(String token) async {
    // ✅ التحقق من وجود driverId
    if (driverId == null) {
      print('⚠️ Cannot update token: driverId is null');
      return;
    }
    
    try {
      // ✅ محاولة استخدام RPC أولاً
      try {
        final response = await supabase.rpc(
          'update_driver_fcm_token',
          params: {
            'p_driver_id': driverId!, // ✅ استخدام ! لأننا تأكدنا من وجوده
            'p_fcm_token': token,
          },
        );
        
        if (response == true) {
          print('✅ Token updated successfully via RPC');
          
          // حفظ التوكن في SharedPreferences
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('fcm_token', token);
          return;
        } else {
          print('❌ Failed to update token via RPC');
        }
      } catch (rpcError) {
        print('⚠️ RPC failed, trying direct update: $rpcError');
      }
      
      // ✅ محاولة التحديث المباشر
      await supabase
          .from('drivers')
          .update({
            'fcm_token': token,
            'last_fcm_sync': DateTime.now().toIso8601String(),
          })
          .eq('id', driverId!); // ✅ استخدام ! لأننا تأكدنا من وجوده
      
      print('✅ Token updated successfully via direct update');
      
      // حفظ التوكن في SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fcm_token', token);
      
    } catch (e) {
      print('❌ Error updating token: $e');
    }
  }

  Future<void> _initFirebaseMessaging() async {
    try {
      FirebaseMessaging messaging = FirebaseMessaging.instance;
      
      // ✅ طلب الإذن
      NotificationSettings settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      
      print('✅ Notification permission: ${settings.authorizationStatus}');
      
      // ✅ تعيين خيارات العرض في المقدمة
      await messaging.setForegroundNotificationPresentationOptions(
        alert: false,
        badge: false,
        sound: false,
      );
      
      // ✅ الحصول على التوكن بالطريقة الرسمية
      String? token = await _getFCMToken();
      
      if (token != null && token.isNotEmpty) {
        fcmToken = token;
        
        // ✅ حفظ في SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('fcm_token', token);
        
        // ✅ إرسال إلى PWA إذا كان جاهزاً
        _sendTokenToPWA(token);
        
        // ✅ إرسال إلى Supabase
        await _updateTokenInDrivers(token);
        
        print('✅ FCM Token initialized: $token');
      } else {
        print('❌ Failed to get FCM token');
      }
      
      // ✅ الاستماع لتحديثات التوكن
      messaging.onTokenRefresh.listen((newToken) async {
        print('🔄 FCM Token refreshed: $newToken');
        fcmToken = newToken;
        
        // ✅ حفظ في SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('fcm_token', newToken);
        
        // ✅ إرسال إلى PWA
        _sendTokenToPWA(newToken);
        
        // ✅ إرسال إلى Supabase
        await _updateTokenInDrivers(newToken);
      });
      
      // ✅ الاستماع للرسائل في المقدمة
      FirebaseMessaging.onMessage.listen((message) {
        print('📩 Received message in foreground: ${message.messageId}');
        _handleFcmMessage(message);
      });
      
      // ✅ الاستماع لفتح التطبيق من الإشعار
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        print('📩 App opened from notification: ${message.messageId}');
        stopGlobalAlertSound();
        _overlayEntry?.remove();
        _overlayEntry = null;
        _handleNotificationClick(message.data);
      });
      
      // ✅ التعامل مع الرسالة الأولية
      messaging.getInitialMessage().then((message) {
        if (message != null) {
          print('📩 Initial message: ${message.messageId}');
          stopGlobalAlertSound();
          _overlayEntry?.remove();
          _overlayEntry = null;
          _handleNotificationClick(message.data);
        }
      });
      
    } catch (e) {
      print('❌ Error in Firebase Messaging setup: $e');
    }
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

  Future<void> _restoreDriver() async {
    final prefs = await SharedPreferences.getInstance();
    driverId = prefs.getString('driver_id');
    
    // ✅ استعادة التوكن من SharedPreferences
    if (driverId != null) {
      final savedToken = prefs.getString('fcm_token');
      if (savedToken != null && savedToken.isNotEmpty) {
        fcmToken = savedToken;
        print('✅ Restored FCM token from SharedPreferences: $fcmToken');
      }
    }
    
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
    
    if (fcmToken != null) {
      await _updateTokenInDrivers(fcmToken!);
    }
    
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

  // ✅ تشغيل الصوت لمدة 30 ثانية فقط
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

    // ✅ إيقاف تلقائي بعد 30 ثانية
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
    
    try { 
      await supabase.from('ride_requests').update({'status': 'accepted'}).eq('ride_id', data['ride_id'] ?? data['rideId']).eq('driver_id', driverId!); 
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
              
              // ✅ Handler لطلب التوكن من PWA
              controller.addJavaScriptHandler(
                handlerName: 'getFCMToken', 
                callback: (args) { 
                  print('📱 PWA requested FCM token');
                  if (fcmToken != null) {
                    // ✅ إرسال التوكن إلى PWA
                    _sendTokenToPWA(fcmToken!);
                    return fcmToken;
                  }
                  return null;
                }
              );
              
              // ✅ Handler لتحديث التوكن من PWA
              controller.addJavaScriptHandler(
                handlerName: 'updateFCMToken',
                callback: (args) async {
                  print('📱 PWA updating FCM token');
                  if (args.isNotEmpty && args[0] != null) {
                    final newToken = args[0].toString();
                    if (newToken.isNotEmpty && newToken != fcmToken) {
                      fcmToken = newToken;
                      await _updateTokenInDrivers(newToken);
                      // ✅ حفظ في SharedPreferences
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString('fcm_token', newToken);
                      return 'OK';
                    }
                  }
                  return 'FAILED';
                }
              );
              
              // ✅ Handler لإيقاف التنبيهات من PWA
              controller.addJavaScriptHandler(
                handlerName: 'stopAlertsFromPWA', 
                callback: (args) { 
                  print(' تم استلام طلب إيقاف التنبيهات من PWA');
                  _stopAlerts(); 
                  return 'OK';
                }
              );
              
              // ✅ Handler لإيقاف التنبيهات
              controller.addJavaScriptHandler(
                handlerName: 'stopAlerts', 
                callback: (args) { 
                  print(' تم استلام طلب إيقاف التنبيهات (stopAlerts)');
                  _stopAlerts();
                  return 'OK';
                }
              );
              
              // ✅ Handler لتسجيل دخول السائق
              controller.addJavaScriptHandler(
                handlerName: 'driverLogin', 
                callback: (args) { 
                  if (args.isNotEmpty && args[0] is Map) {
                    _saveDriver(args[0]['driverId'].toString()); 
                  }
                  return 'OK';
                }
              );

              // ✅ إعلام PWA بأن Flutter جاهز
              controller.evaluateJavascript(source: """
                window.flutterReady = true;
                window.flutterWebViewReady = true;
                window.dispatchEvent(new CustomEvent('flutterReady'));
                console.log('✅ Flutter WebView is ready');
              """);

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
              
              // ✅ إعلام PWA بأن الصفحة تحملت
              await controller.evaluateJavascript(source: """
                window.flutterPageLoaded = true;
                window.dispatchEvent(new CustomEvent('flutterPageLoaded'));
                console.log('✅ Flutter page loaded');
              """);
              
              // ✅ إرسال التوكن إلى PWA إذا كان موجوداً
              if (fcmToken != null) {
                _sendTokenToPWA(fcmToken!);
              }
              
              // ✅ التحقق من صلاحية التوكن
              if (fcmToken != null) {
                final validatedToken = await _validateAndRefreshToken(fcmToken);
                if (validatedToken != null && validatedToken != fcmToken) {
                  fcmToken = validatedToken;
                  _sendTokenToPWA(fcmToken!);
                  await _updateTokenInDrivers(fcmToken!);
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

  void _startDriverSync() {
    Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (web == null) return;
      try {
        final res = await web!.evaluateJavascript(source: "localStorage.getItem('driver_id')");
        if (res != null && res != 'null' && res != driverId) _saveDriver(res);
      } catch (_) {}
    });
  }
}