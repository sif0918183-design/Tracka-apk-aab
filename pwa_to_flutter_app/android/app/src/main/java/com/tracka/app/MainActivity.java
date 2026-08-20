package com.tracka.app;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.media.AudioAttributes;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import androidx.core.app.NotificationCompat;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import org.json.JSONObject;

public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "com.tracka.app/notifications";
    public static final String EMERGENCY_CHANNEL_ID = "emergency_channel_v16";

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        createNotificationChannels();
        
        System.out.println("📱 [MainActivity] onCreate called");
        
        Intent intent = getIntent();
        if (intent != null) {
            System.out.println("📱 [MainActivity] Intent Action: " + intent.getAction());
            handleIntent(intent);
        }
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        
        System.out.println("📱 [MainActivity] onNewIntent called");
        if (intent != null) {
            System.out.println("📱 [MainActivity] Intent Action: " + intent.getAction());
        }
        handleIntent(intent);
    }

    @Override
    protected void onResume() {
        super.onResume();
        System.out.println("📱 [MainActivity] onResume");
        Intent intent = getIntent();
        if (intent != null) {
            handleIntent(intent);
        }
    }

    private void handleIntent(Intent intent) {
        if (intent == null) return;

        String action = intent.getAction();
        String payload = intent.getStringExtra("payload");
        String rideId = intent.getStringExtra("ride_id");
        String type = intent.getStringExtra("type");

        System.out.println("📱 [MainActivity] ========== HANDLE INTENT ==========");
        System.out.println("📱 Action: " + action);
        System.out.println("📱 Ride ID: " + rideId);
        System.out.println("📱 Type: " + type);
        System.out.println("📱 Payload: " + payload);
        System.out.println("📱 ===========================================");

        // ✅ RIDE_REQUEST
        if ("OPEN_RIDE_REQUEST".equals(action) || "RIDE_REQUEST".equals(type)) {
            
            if (rideId == null || rideId.isEmpty()) {
                // ✅ محاولة استخراج ride_id من payload
                if (payload != null && !payload.isEmpty()) {
                    try {
                        JSONObject json = new JSONObject(payload);
                        rideId = json.optString("ride_id", "");
                    } catch (Exception e) {
                        System.out.println("❌ Could not parse payload");
                    }
                }
            }

            if (rideId == null || rideId.isEmpty()) {
                System.out.println("❌ No ride_id available");
                return;
            }

            // ✅ إذا لم يوجد payload نبنيه من البيانات
            if (payload == null || payload.isEmpty()) {
                try {
                    JSONObject json = new JSONObject();
                    json.put("ride_id", rideId);
                    json.put("type", "RIDE_REQUEST");
                    payload = json.toString();
                } catch (Exception e) {
                    System.out.println("❌ Could not create payload");
                    return;
                }
            }

            // ✅ حفظ الطلب المعلق
            SharedPreferences prefs = getSharedPreferences("notification_data", MODE_PRIVATE);
            prefs.edit()
                .putString("pending_payload", payload)
                .putString("pending_ride_id", rideId)
                .putLong("pending_timestamp", System.currentTimeMillis())
                .apply();

            System.out.println("✅ Pending RIDE_REQUEST saved: " + payload);
            return;
        }

        // ✅ التعامل مع payload للإشعارات الأخرى
        if (payload != null && !payload.isEmpty()) {
            SharedPreferences prefs = getSharedPreferences("notification_data", MODE_PRIVATE);
            prefs.edit()
                .putString("pending_payload", payload)
                .putLong("pending_timestamp", System.currentTimeMillis())
                .apply();
        }
    }

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        System.out.println("📱 [MainActivity] configureFlutterEngine called");

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
            .setMethodCallHandler((call, result) -> {
                System.out.println("📱 [MainActivity] MethodChannel call: " + call.method);
                
                if (call.method.equals("showEmergencyNotification")) {
                    String title = call.argument("title");
                    String body = call.argument("body");
                    String payload = call.argument("payload");
                    showEmergencyNotification(title, body, payload);
                    result.success(true);
                    
                } else if (call.method.equals("cancelAllNotifications")) {
                    cancelAllNotifications();
                    result.success(true);
                    
                } else if (call.method.equals("cancelRideNotification")) {
                    String rideId = call.argument("rideId");
                    cancelRideNotification(rideId);
                    result.success(true);
                    
                } else if (call.method.equals("getPendingNotification")) {
                    System.out.println("📱 [MainActivity] getPendingNotification called");
                    
                    SharedPreferences prefs = getSharedPreferences("notification_data", MODE_PRIVATE);
                    String payload = prefs.getString("pending_payload", null);
                    
                    if (payload != null && !payload.isEmpty()) {
                        System.out.println("📱 [MainActivity] Found payload: " + payload);
                        result.success(payload);
                    } else {
                        result.success(null);
                    }
                    
                } else if (call.method.equals("clearPendingNotification")) {
                    System.out.println("📱 [MainActivity] clearPendingNotification called");
                    SharedPreferences prefs = getSharedPreferences("notification_data", MODE_PRIVATE);
                    prefs.edit().clear().apply();
                    result.success(true);
                    
                } else {
                    result.notImplemented();
                }
            });
    }

    private void createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);

            // ✅ قناة الطوارئ مع الصوت
            Uri soundUri = Uri.parse("android.resource://" + getPackageName() + "/raw/ride_request_sound");
            AudioAttributes audioAttributes = new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build();

            NotificationChannel emergencyChannel = new NotificationChannel(
                EMERGENCY_CHANNEL_ID,
                "تنبيهات الطوارئ - تراكا",
                NotificationManager.IMPORTANCE_MAX
            );
            emergencyChannel.setDescription("تنبيهات طلبات الرحلات الجديدة");
            emergencyChannel.setSound(soundUri, audioAttributes);
            emergencyChannel.enableVibration(true);
            emergencyChannel.setVibrationPattern(new long[]{0, 500, 300, 500, 300, 500, 300, 500, 300, 500});
            emergencyChannel.setShowBadge(true);
            emergencyChannel.setLockscreenVisibility(NotificationCompat.VISIBILITY_PUBLIC);
            notificationManager.createNotificationChannel(emergencyChannel);

            // ✅ قناة السفر
            NotificationChannel travelChannel = new NotificationChannel(
                "travel_notifications",
                "إشعارات السفر - تراكا",
                NotificationManager.IMPORTANCE_HIGH
            );
            travelChannel.setDescription("إشعارات قبول الرحلات والمحادثات");
            travelChannel.enableVibration(true);
            travelChannel.setShowBadge(true);
            travelChannel.setLockscreenVisibility(NotificationCompat.VISIBILITY_PUBLIC);
            notificationManager.createNotificationChannel(travelChannel);

            // ✅ قناة الخدمة
            NotificationChannel serviceChannel = new NotificationChannel(
                "foreground_service",
                "خدمة تراكا تعمل حالياً",
                NotificationManager.IMPORTANCE_LOW
            );
            serviceChannel.setDescription("إشعارات خدمة الخلفية");
            notificationManager.createNotificationChannel(serviceChannel);

            System.out.println("✅ Native notification channels created");
        }
    }

    public static void showEmergencyNotificationStatic(Context context, String title, String body, String payload) {
        try {
            NotificationManager notificationManager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);

            Intent intent = new Intent(context, MainActivity.class);
            intent.setAction("OPEN_RIDE_REQUEST");
            intent.putExtra("payload", payload);
            intent.putExtra("type", "RIDE_REQUEST");
            
            try {
                JSONObject json = new JSONObject(payload);
                String rideId = json.optString("ride_id");
                if (rideId != null && !rideId.isEmpty()) {
                    intent.putExtra("ride_id", rideId);
                }
            } catch (Exception e) {
                System.err.println("⚠️ Could not parse ride_id from payload");
            }
            
            intent.setFlags(
                Intent.FLAG_ACTIVITY_CLEAR_TOP |
                Intent.FLAG_ACTIVITY_SINGLE_TOP |
                Intent.FLAG_ACTIVITY_NEW_TASK
            );

            int requestCode = (int) System.currentTimeMillis();
            try {
                JSONObject json = new JSONObject(payload);
                String rideId = json.optString("ride_id");
                if (rideId != null && !rideId.isEmpty()) {
                    requestCode = rideId.hashCode();
                }
            } catch (Exception e) {}

            PendingIntent pendingIntent = PendingIntent.getActivity(
                context,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
            );

            NotificationCompat.Builder notification = new NotificationCompat.Builder(context, EMERGENCY_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setAutoCancel(false)
                .setOngoing(true)
                .setVibrate(new long[]{0, 500, 300, 500, 300, 500, 300, 500, 300, 500, 300, 500})
                .setContentIntent(pendingIntent)
                .setStyle(new NotificationCompat.BigTextStyle().bigText(body));

            try {
                int soundResId = context.getResources().getIdentifier("ride_request_sound", "raw", context.getPackageName());
                if (soundResId > 0) {
                    notification.setSound(Uri.parse("android.resource://" + context.getPackageName() + "/raw/ride_request_sound"));
                }
            } catch (Exception e) {
                System.err.println("⚠️ Sound resource not found");
            }

            int notificationId = (int) System.currentTimeMillis();
            notificationManager.notify(notificationId, notification.build());

            System.out.println("✅ Native notification shown: " + title);

        } catch (Exception e) {
            System.err.println("❌ Error showing native notification: " + e.getMessage());
            e.printStackTrace();
        }
    }

    private void showEmergencyNotification(String title, String body, String payload) {
        showEmergencyNotificationStatic(this, title, body, payload);
    }

    private void cancelAllNotifications() {
        try {
            NotificationManager notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            notificationManager.cancelAll();
            System.out.println("✅ All notifications cancelled");
        } catch (Exception e) {
            System.err.println("❌ Error cancelling notifications: " + e.getMessage());
        }
    }

    public void cancelRideNotification(String rideId) {
        if (rideId == null || rideId.isEmpty()) {
            return;
        }
        try {
            NotificationManager notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            notificationManager.cancel(rideId.hashCode());
            System.out.println("✅ Ride notification cancelled: " + rideId);
        } catch (Exception e) {
            System.err.println("❌ Error cancelling ride notification: " + e.getMessage());
        }
    }
}