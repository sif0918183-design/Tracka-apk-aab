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

// ✅ MethodChannel للتواصل مع Native
final MethodChannel _methodChannel = MethodChannel('com.tracka.driver/alerts');

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

// ✅ دالة عامة لإيقاف الصوت والاهتزاز
void stopGlobalAlertSound() {
  print('🔇 [GLOBAL] محاولة إيقاف الصوت والاهتزاز...');
  
  _globalIsAlertPlaying = false;
  
  if (_globalAlertTimer != null) {
    _globalAlertTimer!.cancel();
    _globalAlertTimer = null;
  }
  
  try {
    if (_globalAudioPlayer != null) {
      _globalAudioPlayer!.stop();
      _globalAudioPlayer!.dispose();
      _globalAudioPlayer = null;
    }
  } catch (e) {
    print('⚠️ [GLOBAL] خطأ في إيقاف مشغل الصوت: $e');
  }
  
  try {
    Vibration.cancel();
  } catch (e) {
    print('⚠️ [GLOBAL] خطأ في إلغاء الاهتزاز: $e');
  }
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
  
  Future.delayed(const Duration(seconds: 35), () {
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
          autoCancel: false,
          category: fln.AndroidNotificationCategory.call,
          playSound: true,
          enableVibration: true,
          additionalFlags: Int32List.fromList([4]),
          vibrationPattern: Int64List.fromList([0, 600, 200, 600, 200, 600, 200, 600]),
          sound: const fln.RawResourceAndroidNotificationSound('ride_request_sound'),
          channelShowBadge: true,
          visibility: fln.NotificationVisibility.public,
          timeoutAfter: 35000,
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
  
  // ✅ قناة مراقبة إيقاف التنبيهات عبر Supabase Realtime
  RealtimeChannel? _rideAlertChannel;
  String? _currentDriverId;
  
  OverlayEntry? _overlayEntry;
  bool _isAcceptPageOpen = false;

  @override
  void initState() {
    super.initState();
    
    _methodChannel.setMethodCallHandler((call) async {
      if (call.method == 'stopAlerts') {
        _stopAlerts();
        return true;
      }
      return false;
    });
    
    _initNotifications();
    _initFirebaseMessaging();
    _restoreDriver();
    _initConnectivity();
    
    // ✅ بدء مراقبة إيقاف التنبيهات عبر Supabase Realtime
    _initDriverAlertListener();
  }

  @override
  void dispose() {
    _stopAlerts();
    statusSyncTimer?.cancel();
    connectivitySubscription?.cancel();
    _rideAlertChannel?.unsubscribe();
    super.dispose();
  }

  // ============================================================
  // ✅ دالة بدء مراقبة العمود المخصص لإيقاف الصوت
  // ============================================================
  void _startListeningToAlertStop(String driverId) {
    _currentDriverId = driverId;

    // إلغاء أي اشتراك سابق إن وجد
    _rideAlertChannel?.unsubscribe();

    _rideAlertChannel = Supabase.instance.client
        .channel('public:rides:alert_stop_$driverId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'rides',
          callback: (payload) async {
            final newRecord = payload.newRecord;
            final openedByDriverId = newRecord['alert_opened_by_driver_id']?.toString();

            debugPrint('⚡ تحديث جديد في جدول rides: openedByDriverId=$openedByDriverId');

            // المقارنة المباشرة بين driver_id السائق الحالي والعمود الجديد
            if (openedByDriverId != null && openedByDriverId == _currentDriverId) {
              debugPrint('🛑 تطابق معرّف السائق! إيقاف الصوت والاهتزاز والإشعارات فوراً.');
              
              // ✅ إيقاف التنبيهات فوراً
              _stopAlerts();
              
              // ✅ إيقاف الصوت العالمي أيضاً للتأكيد
              stopGlobalAlertSound();
            }
          },
        )
        .subscribe();
        
    debugPrint('✅ بدء مراقبة إيقاف التنبيهات للسائق: $driverId');
  }

  // ============================================================
  // ✅ دالة جلب معرّف السائق وتشغيل المراقبة
  // ============================================================
  Future<void> _initDriverAlertListener() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // محاولة جلب driverId من عدة مصادر محتملة
      String? driverIdFromPrefs;
      
      // 1. من tarhal_driver (المستخدم في PWA)
      final driverJson = prefs.getString('tarhal_driver');
      if (driverJson != null) {
        try {
          final driverData = jsonDecode(driverJson);
          driverIdFromPrefs = driverData['id']?.toString();
        } catch (e) {
          debugPrint('⚠️ خطأ في قراءة tarhal_driver: $e');
        }
      }
      
      // 2. من driver_id (المستخدم في Flutter)
      if (driverIdFromPrefs == null) {
        driverIdFromPrefs = prefs.getString('driver_id');
      }
      
      if (driverIdFromPrefs != null) {
        _startListeningToAlertStop(driverIdFromPrefs);
        debugPrint('✅ تم تفعيل مراقبة إيقاف التنبيهات للسائق: $driverIdFromPrefs');
      } else {
        debugPrint('⚠️ لم يتم العثور على driverId لتفعيل مراقبة إيقاف التنبيهات');
      }
    } catch (e) {
      debugPrint('❌ خطأ في تحميل معرّف السائق للمراقبة: $e');
    }
  }

  // ============================================================
  // ✅ دالة تحديث السائق عند تغييره
  // ============================================================
  Future<void> _saveDriver(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('driver_id', id);
    driverId = id;
    
    if (fcmToken != null) {
      await _updateTokenInDrivers(fcmToken!);
    }
    
    // ✅ تحديث مراقبة إيقاف التنبيهات للسائق الجديد
    _startListeningToAlertStop(id);
    
    _listenForRides();
    _notifyPWAOfDriver(id);
    _startForegroundService();
  }

  Future<void> _updateTokenInDrivers(String token) async {
    if (driverId == null) return;
    try {
      await supabase.rpc(
        'update_driver_fcm_token',
        params: {
          'p_driver_id': driverId,
          'p_fcm_token': token,
        },
      );
    } catch (e) {
      print('❌ Error updating token via RPC: $e');
    }
  }

  Future<void> _initNotifications() async {
    const androidInit = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
    await notifications.initialize(
      const fln.InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: (details) {
        _stopAlerts();
        if (details.payload != null) _handleNotificationClick(jsonDecode(details.payload!));
      }
    );

    final androidImplementation = notifications.resolvePlatformSpecificImplementation<fln.AndroidFlutterLocalNotificationsPlugin>();

    if (androidImplementation != null) {
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
      
      const travelChan = fln.AndroidNotificationChannel(
        'travel_notifications',
        'إشعارات السفر - تراكا',
        description: 'إشعارات قبول الرحلات والمحادثات',
        importance: fln.Importance.high,
        playSound: true,
        enableVibration: true,
      );
      await androidImplementation.createNotificationChannel(travelChan);
    }
  }

  Future<void> _initFirebaseMessaging() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    
    await messaging.setForegroundNotificationPresentationOptions(
      alert: false,
      badge: false,
      sound: false,
    );
    
    fcmToken = await messaging.getToken();
    if (fcmToken != null) {
      _sendTokenToPWA(fcmToken!);
      await _updateTokenInDrivers(fcmToken!);
    }
    messaging.onTokenRefresh.listen((newToken) async { 
      fcmToken = newToken; 
      _sendTokenToPWA(newToken);
      await _updateTokenInDrivers(newToken);
    });
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _stopAlerts();
      _handleNotificationClick(message.data);
    });
    messaging.getInitialMessage().then((message) { 
      if (message != null) {
        _stopAlerts();
        _handleNotificationClick(message.data); 
      }
    });
    
    FirebaseMessaging.onMessage.listen((message) {
      _handleFcmMessage(message);
    });
  }

  void _handleNotificationClick(Map<String, dynamic> data) {
    final String notifType = data['type']?.toString() ?? '';
    final bool isTravelNotif = _travelTypes.contains(notifType);

    _stopAlerts();

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

      _stopAlerts();
      _playAlertSound();
      _showRideRequestModal(data);
      await _showLocalNotification(data);
      await _sendToPWA(data);
      return;
    }

    await _showTravelNotification(data, message.notification?.title, message.notification?.body);
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
    _stopAlerts();
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

    Future.delayed(const Duration(seconds: 35), () {
      _stopAlerts();
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
      }
    } catch (_) {}
  }

  void _stopAlerts() async {
    print('🛑 إيقاف جميع التنبيهات المباشرة والتنفيذية...');
    
    stopGlobalAlertSound();
    
    if (_overlayEntry != null) {
      try {
        _overlayEntry!.remove();
      } catch (_) {}
      _overlayEntry = null;
    }
    
    try {
      await notifications.cancelAll();
    } catch (e) {
      print('⚠️ خطأ في إلغاء الإشعارات: $e');
    }

    try {
      await Vibration.cancel();
    } catch (_) {}

    try {
      await _methodChannel.invokeMethod('stopAlerts');
    } catch (_) {}
    
    _isAcceptPageOpen = false;
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
            autoCancel: false,
            category: fln.AndroidNotificationCategory.call,
            playSound: true,
            enableVibration: true,
            additionalFlags: Int32List.fromList([4]),
            vibrationPattern: Int64List.fromList([0, 600, 200, 600, 200, 600, 200, 600]),
            sound: const fln.RawResourceAndroidNotificationSound('ride_request_sound'),
            channelShowBadge: true,
            visibility: fln.NotificationVisibility.public,
            timeoutAfter: 35000,
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
    if (_overlayEntry != null) {
      try { _overlayEntry!.remove(); } catch (_) {}
      _overlayEntry = null;
    }
    
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
    _stopAlerts();
    
    try { 
      await supabase.from('ride_requests').update({'status': 'accepted'}).eq('ride_id', data['ride_id'] ?? data['rideId']).eq('driver_id', driverId!); 
    } catch (_) {}
    
    final rideId = _extractRideId(data);
    if (rideId != null && web != null) {
      _isAcceptPageOpen = true;
      final url = "https://tracka.zoonasd.com/driver_app/accept-ride.html?id=$rideId";
      await web!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
  }

  void _rejectRide() {
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
              
              controller.addJavaScriptHandler(
                handlerName: 'stopAlertsFromPWA', 
                callback: (args) { 
                  _stopAlerts(); 
                  return 'OK';
                }
              );
              
              controller.addJavaScriptHandler(
                handlerName: 'stopAlerts', 
                callback: (args) { 
                  _stopAlerts();
                  return 'OK';
                }
              );
              
              controller.addJavaScriptHandler(
                handlerName: 'isAlertPlaying', 
                callback: (args) { 
                  return _globalIsAlertPlaying;
                }
              );
              
              controller.addJavaScriptHandler(
                handlerName: 'driverLogin', 
                callback: (args) { 
                  if (args.isNotEmpty && args[0] is Map) {
                    _saveDriver(args[0]['driverId'].toString()); 
                  }
                  return 'OK';
                }
              );

              if (_pendingUrl != null) {
                controller.loadUrl(urlRequest: URLRequest(url: WebUri(_pendingUrl!)));
              }
            },
            onLoadStart: (controller, url) {
              if (url != null && url.toString().contains('accept-ride.html')) {
                _isAcceptPageOpen = true;
                _stopAlerts();
              }
            },
            onUpdateVisitedHistory: (controller, url, isReload) {
              if (url != null && url.toString().contains('accept-ride.html')) {
                _isAcceptPageOpen = true;
                _stopAlerts();
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
                  _isAcceptPageOpen = true;
                  _stopAlerts();
                } else {
                  _isAcceptPageOpen = false;
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
      try {
        final res = await web!.evaluateJavascript(source: "localStorage.getItem('driver_id')");
        if (res != null && res != 'null' && res != driverId) _saveDriver(res);
      } catch (_) {}
    });
  }
}