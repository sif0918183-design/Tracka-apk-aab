package com.tracka.app;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import androidx.core.app.NotificationCompat;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "com.tracka.app/notifications";

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        createNotificationChannels();
    }

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
            .setMethodCallHandler((call, result) -> {
                if (call.method.equals("showEmergencyNotification")) {
                    String title = call.argument("title");
                    String body = call.argument("body");
                    String payload = call.argument("payload");
                    showEmergencyNotification(title, body, payload);
                    result.success(true);
                } else if (call.method.equals("cancelAllNotifications")) {
                    cancelAllNotifications();
                    result.success(true);
                } else {
                    result.notImplemented();
                }
            });
    }

    private void createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);

            // ✅ قناة الطوارئ
            NotificationChannel emergencyChannel = new NotificationChannel(
                "emergency_channel_v15",
                "تنبيهات الطوارئ - تراكا",
                NotificationManager.IMPORTANCE_MAX
            );
            emergencyChannel.setDescription("قناة الطوارئ للرحلات الجديدة - صوت عالٍ واهتزاز قوي");
            emergencyChannel.enableVibration(true);
            emergencyChannel.setVibrationPattern(new long[]{0, 500, 300, 500, 300, 500, 300, 500, 300, 500, 300, 500});
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

    private void showEmergencyNotification(String title, String body, String payload) {
        try {
            NotificationManager notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);

            Intent intent = new Intent(this, MainActivity.class);
            intent.putExtra("payload", payload);
            intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);

            PendingIntent pendingIntent = PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
            );

            NotificationCompat.Builder notification = new NotificationCompat.Builder(this, "emergency_channel_v15")
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

            // ✅ إضافة الصوت إذا كان موجوداً
            try {
                int soundResId = getResources().getIdentifier("ride_request_sound", "raw", getPackageName());
                if (soundResId > 0) {
                    notification.setSound(android.net.Uri.parse("android.resource://" + getPackageName() + "/raw/ride_request_sound"));
                }
            } catch (Exception e) {
                System.err.println("⚠️ Sound resource not found, using default");
            }

            int notificationId = (int) System.currentTimeMillis();
            notificationManager.notify(notificationId, notification.build());
            
            System.out.println("✅ Native notification shown: " + title);
            
        } catch (Exception e) {
            System.err.println("❌ Error showing native notification: " + e.getMessage());
        }
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
}