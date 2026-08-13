package com.tracka.app;

import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import androidx.core.app.NotificationCompat;
import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

public class MyFirebaseMessagingService extends FirebaseMessagingService {

    @Override
    public void onMessageReceived(RemoteMessage message) {
        super.onMessageReceived(message);

        try {
            // ✅ استخراج البيانات
            String type = message.getData().get("type");
            String title = message.getNotification() != null ?
                message.getNotification().getTitle() : "🚨 طلب رحلة جديد";
            String body = message.getNotification() != null ?
                message.getNotification().getBody() : "يوجد طلب رحلة جديد في انتظارك";
            String payload = message.getData().toString();

            System.out.println("📱 [FCM Service] Received message type: " + type);
            System.out.println("📱 [FCM Service] Title: " + title);
            System.out.println("📱 [FCM Service] Body: " + body);

            // ✅ إذا كان RIDE_REQUEST، اعرض إشعار الطوارئ
            if ("RIDE_REQUEST".equals(type)) {
                showEmergencyNotification(title, body, payload);
            } else {
                // إشعار عادي
                showNormalNotification(title, body, payload);
            }

        } catch (Exception e) {
            System.err.println("❌ [FCM Service] Error: " + e.getMessage());
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

            NotificationCompat.Builder notification = new NotificationCompat.Builder(this, MainActivity.EMERGENCY_CHANNEL_ID)
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

            System.out.println("✅ [FCM Service] Emergency notification shown: " + title);

        } catch (Exception e) {
            System.err.println("❌ [FCM Service] Error showing emergency notification: " + e.getMessage());
        }
    }

    private void showNormalNotification(String title, String body, String payload) {
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

            NotificationCompat.Builder notification = new NotificationCompat.Builder(this, "travel_notifications")
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent);

            int notificationId = (int) System.currentTimeMillis();
            notificationManager.notify(notificationId, notification.build());

            System.out.println("✅ [FCM Service] Normal notification shown: " + title);

        } catch (Exception e) {
            System.err.println("❌ [FCM Service] Error showing normal notification: " + e.getMessage());
        }
    }
}