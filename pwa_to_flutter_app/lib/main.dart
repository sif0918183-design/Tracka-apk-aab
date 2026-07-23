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
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'webview_popup.dart';

// ✅ Global Navigator Key for Overlay
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// أنواع إشعارات منصة السفر (الهادئة)
const _travelTypes = {'DRIVER_OFFER', 'DRIVER_SELECTED', 'NEW_CHAT_MESSAGE'};

// ✅ نوع إشعار الرحلة الفورية (الطوارئ)
const String _rideRequestType = 'RIDE_REQUEST';

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

// ✅ تشغيل الصوت والاهتزاز المتكرر في الخلفية (للرحلات الفورية فقط)
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

RealtimeChannel? _bgRideStatusChannel;

void _listenForRideStatusChangesBackground(String rideId) {
  try {
    Supabase.initialize(
      url: const String.fromEnvironment('SUPABASE_URL'),
      anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'),
    );
  } catch (_) {}

  final supabase = Supabase.instance.client;
  _bgRideStatusChannel?.unsubscribe();
  _bgRideStatusChannel = supabase.channel('bg_ride_status_$rideId')
    ..onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'rides',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'id',
        value: rideId,
      ),
      callback: (payload) {
        final data = payload.newRecord;
        if (data != null) {
          final String status = data['status']?.toString() ?? '';
          if (status == 'accepted' ||
              status == 'cancelled_by_customer' ||
              status == 'no_drivers_found' ||
              status == 'completed') {

            _stopAlertSoundInBackground();
            try {
              FlutterOverlayWindow.closeOverlay();
            } catch (_) {}

            _bgRideStatusChannel?.unsubscribe();
            _bgRideStatusChannel = null;
          }
        }
      },
    )..subscribe();
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  Map<String, dynamic> data = message.data;
  final String notifType = data['type']?.toString() ?? '';
  final bool isTravelNotif = _travelTypes.contains(notifType);
  final bool isRideRequest = (notifType == _rideRequestType);

  // ✅ فقط إشعارات RIDE_REQUEST تشغل الصوت والاهتزاز في الخلفية
  if (isRideRequest) {
    String? rideId = _extractRideId(data);
    if (await _isDuplicateRide(rideId)) return;
    
    // ✅ تشغيل الصوت والاهتزاز المتكرر عند استلام إشعار رحلة فورية في الخلفية
    _playAlertSoundInBackground();

    // ✅ عرض النافذة العائمة في الخلفية
    try {
      if (await FlutterOverlayWindow.isPermissionGranted()) {
        if (!await FlutterOverlayWindow.isActive()) {
          await FlutterOverlayWindow.showOverlay(
            height: 240,
            width: 340,
            alignment: OverlayAlignment.center,
            enableDrag: true,
            overlayTitle: "طلب رحلة جديد",
            overlayContent: "لديك طلب رحلة جديد من العميل",
          );
        }
        Future.delayed(const Duration(milliseconds: 500), () {
          FlutterOverlayWindow.shareData(jsonEncode(data));
        });
      }
    } catch (_) {}

    // ✅ الاستماع لتغيرات حالة الرحلة في الخلفية
    if (rideId != null) {
      _listenForRideStatusChangesBackground(rideId);
    }
  }

  final fln.FlutterLocalNotificationsPlugin notifications = fln.FlutterLocalNotificationsPlugin();
  const android = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
  await notifications.initialize(const fln.InitializationSettings(android: android));

  String title = message.notification?.title ?? (isTravelNotif ? 'تراكا' : '🚨 طلب رحلة جديد');
  String body = message.notification?.body ?? (isTravelNotif ? 'لديك إشعار جديد' : 'يوجد طلب رحلة جديد في انتظارك');

  // ✅ إشعارات السفر (هادئة) تستخدم قناة travel_notifications
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
    // ✅ إشعارات RIDE_REQUEST (طوارئ) تستخدم القناة الخاصة
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
    Permission.systemAlertWindow,
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
      navigatorKey: navigatorKey,  // ✅ لإستخدام Overlay
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
  Map<String, dynamic>? _activeRideData;
  RealtimeChannel? _rideStatusChannel;
  StreamSubscription? _overlayEventSubscription;

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _initFirebaseMessaging();
    _restoreDriver();
    _initConnectivity();

    // ✅ Listen for events from the floating overlay window
    _overlayEventSubscription = FlutterOverlayWindow.overlayListener.listen((event) {
      if (event == "request_data") {
        if (_activeRideData != null) {
          FlutterOverlayWindow.shareData(jsonEncode(_activeRideData));
        }
      } else if (event == "accept") {
        if (_activeRideData != null) {
          _acceptRide(_activeRideData!);
        }
      } else if (event == "reject") {
        _rejectRide();
      }
    });
  }

  @override
  void dispose() {
    _stopAlertSound();
    _overlayEntry?.remove();
    _overlayEntry = null;
    _overlayEventSubscription?.cancel();
    _rideStatusChannel?.unsubscribe();
    statusSyncTimer?.cancel();
    connectivitySubscription?.cancel();
    _globalAudioPlayer?.dispose();
    try {
      FlutterOverlayWindow.closeOverlay();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _initNotifications() async {
    const androidInit = fln.AndroidInitializationSettings('@mipmap/ic_launcher');
    await notifications.initialize(
      const fln.InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: (details) {
        _stopAlertSound();
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
        audioAttributesUsage: fln.AudioAttributesUsage.alarm,
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

  // ✅ ✅ ✅ الدالة لتحديث التوكن عبر RPC ✅ ✅ ✅
  Future<void> _updateTokenInDrivers(String token) async {
    if (driverId == null) return;
    try {
      final response = await supabase.rpc(
        'update_driver_fcm_token',
        params: {
          'p_driver_id': driverId,
          'p_fcm_token': token,
        },
      );
      
      if (response == true) {
        print('✅ Token updated successfully via RPC');
      } else {
        print('❌ Failed to update token via RPC');
      }
    } catch (e) {
      print('❌ Error updating token via RPC: $e');
    }
  }

  Future<void> _initFirebaseMessaging() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    
    // ✅ منع Firebase من عرض الإشعار في المقدمة (لتجنب التكرار)
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
      _stopAlertSound();
      _overlayEntry?.remove();
      _overlayEntry = null;
      _handleNotificationClick(message.data);
    });
    messaging.getInitialMessage().then((message) { 
      if (message != null) {
        _stopAlertSound();
        _overlayEntry?.remove();
        _overlayEntry = null;
        _handleNotificationClick(message.data); 
      }
    });
    
    // ✅ معالجة الإشعار عند وصوله والتطبيق في المقدمة
    FirebaseMessaging.onMessage.listen((message) {
      _handleFcmMessage(message);
    });
  }

  void _handleNotificationClick(Map<String, dynamic> data) {
    final String notifType = data['type']?.toString() ?? '';
    final bool isTravelNotif = _travelTypes.contains(notifType);

    _stopAlertSound();
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

  // ✅ ✅ ✅ معالجة الإشعارات مع تمييز الأنواع ومنع التكرار ✅ ✅ ✅
  void _handleFcmMessage(RemoteMessage message) async {
    Map<String, dynamic> data = Map<String, dynamic>.from(message.data);
    final String notifType = data['type']?.toString() ?? '';
    final bool isTravelNotif = _travelTypes.contains(notifType);
    final bool isRideRequest = (notifType == _rideRequestType);

    // ✅ إشعارات السفر (DRIVER_OFFER, DRIVER_SELECTED, NEW_CHAT_MESSAGE)
    // تظهر كإشعار عادي بدون صوت/اهتزاز متصل
    if (isTravelNotif) {
      await _showTravelNotification(data, title: message.notification?.title, body: message.notification?.body);
      return;
    }

    // ✅ إشعارات RIDE_REQUEST (الرحلات الفورية)
    // تشغل الصوت والاهتزاز المتصل + نافذة منبثقة ثابتة
    if (isRideRequest) {
      String? rideId = _extractRideId(data);
      if (await _isDuplicateRide(rideId)) return;

      _stopAlertSound();
      _playAlertSound();
      
      // ✅ عرض النافذة المنبثقة الثابتة (باستخدام Overlay)
      _showRideRequestModal(data);

      // ✅ عرض النافذة العائمة (Floating Window)
      _showFloatingWindow(data);
      
      // ✅ إرسال إلى PWA
      await _sendToPWA(data);
      
      // ✅ ✅ ✅ لا نعرض إشعاراً محلياً (لتجنب التكرار مع إشعار Firebase)
      return;
    }

    // ✅ أي إشعار آخر (احتياطي) - يظهر كإشعار عادي
    await _showTravelNotification(data, title: message.notification?.title, body: message.notification?.body);
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
    
    // ✅ ✅ ✅ حفظ التوكن عند تسجيل الدخول
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
          _showFloatingWindow(rideData);
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

    // ✅ إيقاف تلقائي بعد 35 ثانية (الصوت فقط، النافذة تبقى)
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

  // ✅ إشعارات السفر العادية (بدون صوت/اهتزاز متصل)
  Future<void> _showTravelNotification(Map<String, dynamic> data, {String? title, String? body}) async {
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

  // ✅ Helper method to extract ride id
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

  // ✅ ✅ ✅ نافذة منبثقة ثابتة باستخدام Overlay ✅ ✅ ✅
  void _showRideRequestModal(Map<String, dynamic> data) {
    // ✅ إزالة أي نافذة سابقة
    _overlayEntry?.remove();
    
    // ✅ الحصول على context صحيح
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

    // ✅ عرض النافذة فوق كل شيء
    Overlay.of(context).insert(_overlayEntry!);
  }

  Future<void> _showFloatingWindow(Map<String, dynamic> data) async {
    _activeRideData = data;
    final String? rideId = _extractRideId(data);

    // Request permission if not granted
    if (!await FlutterOverlayWindow.isPermissionGranted()) {
      await FlutterOverlayWindow.requestPermission();
    }

    // If permission is granted, show overlay
    if (await FlutterOverlayWindow.isPermissionGranted()) {
      if (!await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.showOverlay(
          height: 240,
          width: 340,
          alignment: OverlayAlignment.center,
          enableDrag: true,
          overlayTitle: "طلب رحلة جديد",
          overlayContent: "لديك طلب رحلة جديد من العميل",
        );
      }

      // Delay and share data with overlay
      Future.delayed(const Duration(milliseconds: 500), () {
        FlutterOverlayWindow.shareData(jsonEncode(data));
      });

      // Listen for ride status changes in Supabase
      if (rideId != null) {
        _listenForRideStatusChanges(rideId);
      }
    }
  }

  void _listenForRideStatusChanges(String rideId) {
    _rideStatusChannel?.unsubscribe();
    _rideStatusChannel = supabase.channel('ride_status_$rideId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'rides',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'id',
          value: rideId,
        ),
        callback: (payload) {
          final data = payload.newRecord;
          if (data != null) {
            final String status = data['status']?.toString() ?? '';
            if (status == 'accepted' ||
                status == 'cancelled_by_customer' ||
                status == 'no_drivers_found' ||
                status == 'completed') {

              // إيقاف الصوت والاهتزاز تلقائياً
              _stopAlerts();

              // إلغاء الإشعار المحلي
              try {
                notifications.cancel(rideId.hashCode);
              } catch (_) {}

              // عرض إشعار عادي يوضح الحالة الجديدة
              String message = 'تغيرت حالة الرحلة';
              if (status == 'accepted') {
                message = 'تم قبول الرحلة بنجاح';
              } else if (status == 'cancelled_by_customer') {
                message = 'تم إلغاء الرحلة من قبل العميل';
              } else if (status == 'no_drivers_found') {
                message = 'لم يتم العثور على سائقين للرحلة';
              } else if (status == 'completed') {
                message = 'تم إكمال الرحلة بنجاح';
              }

              _showTravelNotification(
                {'type': 'RIDE_STATUS_UPDATE', 'ride_id': rideId},
                title: 'تحديث الرحلة',
                body: message,
              );

              // إلغاء الاستماع
              _rideStatusChannel?.unsubscribe();
              _rideStatusChannel = null;
            }
          }
        },
      )..subscribe();
  }

  Future<void> _acceptRide(Map<String, dynamic> data) async {
    _stopAlerts();
    final String? rideId = _extractRideId(data);

    if (rideId != null) {
      try {
        // تحديث جدول rides
        await supabase.from('rides').update({'status': 'accepted'}).eq('id', rideId);
      } catch (_) {}
      try {
        // تحديث جدول ride_requests
        await supabase.from('ride_requests').update({'status': 'accepted'}).eq('ride_id', rideId).eq('driver_id', driverId!);
      } catch (_) {}
    }

    // فتح صفحة القبول في الـ WebView
    if (rideId != null) {
      final url = "https://tracka.zoonasd.com/driver_app/accept-ride.html?id=$rideId";
      if (web != null) {
        await web!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
      }
    }
  }

  void _rejectRide() {
    _stopAlerts();
  }

  void _stopAlerts() {
    _stopAlertSound();
    _overlayEntry?.remove();
    _overlayEntry = null;
    Vibration.cancel();
    notifications.cancelAll();
    try {
      FlutterOverlayWindow.closeOverlay();
    } catch (_) {}
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

// ✅ Entry point for Overlay (Floating Window)
@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MyOverlayWidget(),
    ),
  );
}

class MyOverlayWidget extends StatefulWidget {
  const MyOverlayWidget({super.key});

  @override
  State<MyOverlayWidget> createState() => _MyOverlayWidgetState();
}

class _MyOverlayWidgetState extends State<MyOverlayWidget> {
  String _customerName = "جاري التحميل...";
  String _amount = "0";
  String? _rideId;
  StreamSubscription? _overlaySubscription;

  @override
  void initState() {
    super.initState();
    // Listen for data from the main application
    _overlaySubscription = FlutterOverlayWindow.overlayListener.listen((event) {
      if (event != null && event is String && event != "request_data" && event != "accept" && event != "reject") {
        try {
          final decoded = jsonDecode(event);
          setState(() {
            _customerName = decoded['customer_name'] ?? decoded['customerName'] ?? "عميل";
            _amount = (decoded['amount'] ?? decoded['price'] ?? "0").toString();
            _rideId = (decoded['ride_id'] ?? decoded['rideId'] ?? decoded['id'] ?? '').toString();
          });
        } catch (_) {}
      }
    });

    // Request data from main application after startup
    Future.delayed(const Duration(milliseconds: 300), () {
      FlutterOverlayWindow.shareData("request_data");
    });
  }

  @override
  void dispose() {
    _overlaySubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Container(
            width: double.infinity,
            height: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.blueAccent.withOpacity(0.5), width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 15,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Drag handle bar indicator
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 4),
                // Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.stars, color: Colors.amber, size: 24),
                    SizedBox(width: 8),
                    Text(
                      "طلب رحلة فوري 🚨",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 16),
                // Ride Details
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _customerName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.black54,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          "$_amount SDG",
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.green,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Accept / Reject Buttons
                Row(
                  children: [
                    // Accept Button
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 2,
                        ),
                        onPressed: () async {
                          FlutterOverlayWindow.shareData("accept");
                          if (_rideId != null && _rideId!.isNotEmpty) {
                            try {
                              final uri = Uri.parse("https://tracka.zoonasd.com/driver_app/accept-ride.html?id=$_rideId");
                              await launchUrl(uri, mode: LaunchMode.externalApplication);
                            } catch (_) {}
                          }
                          try {
                            await FlutterOverlayWindow.closeOverlay();
                          } catch (_) {}
                        },
                        child: const Text(
                          "قبول",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Reject Button
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 2,
                        ),
                        onPressed: () async {
                          FlutterOverlayWindow.shareData("reject");
                          try {
                            await FlutterOverlayWindow.closeOverlay();
                          } catch (_) {}
                        },
                        child: const Text(
                          "رفض",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
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
    );
  }
} 