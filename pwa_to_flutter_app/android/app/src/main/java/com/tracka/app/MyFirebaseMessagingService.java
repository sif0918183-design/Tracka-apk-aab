package com.tracka.app;

import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import androidx.core.app.NotificationCompat;
import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;
import org.json.JSONObject;

public class MyFirebaseMessagingService extends FirebaseMessagingService {

    @Override
    public void onMessageReceived(RemoteMessage message) {
        super.onMessageReceived(message);

        try {
            // ✅ استخراج البيانات من RemoteMessage
            String type = message.getData().get("type");
            String rideId = message.getData().get("ride_id");
            String customerName = message.getData().get("customer_name");
            String amount = message.getData().get("amount");
            
            // ✅ إذا لم توجد ride_id في data، حاول من notification
            if (rideId == null || rideId.isEmpty()) {
                Bundle extras = message.toIntent().getExtras();
                if (extras != null) {
                    rideId = extras.getString("ride_id");
                }
            }

            String title = message.getNotification() != null ?
                message.getNotification().getTitle() : "🚨 طلب رحلة جديد";
            String body = message.getNotification() != null ?
                message.getNotification().getBody() : "يوجد طلب رحلة جديد في انتظارك";

            // ✅ بناء payload كامل مع جميع البيانات
            JSONObject payload = new JSONObject();
            payload.put("ride_id", rideId != null ? rideId : "");
            payload.put("type", type != null ? type : "RIDE_REQUEST");
            payload.put("customer_name", customerName != null ? customerName : "");
            payload.put("amount", amount != null ? amount : "0");
            
            String payloadString = payload.toString();

            System.out.println("📱 [FCM Service] Received message");
            System.out.println("📱 [FCM Service] Type: " + type);
            System.out.println("📱 [FCM Service] Ride ID: " + rideId);
            System.out.println("📱 [FCM Service] Title: " + title);
            System.out.println("📱 [FCM Service] Body: " + body);
            System.out.println("📱 [FCM Service] Payload: " + payloadString);

            // ✅ إذا كان RIDE_REQUEST، اعرض إشعار الطوارئ
            if ("RIDE_REQUEST".equals(type)) {
                showEmergencyNotification(title, body, payloadString, rideId);
            } else {
                showNormalNotification(title, body, payloadString);
            }

        } catch (Exception e) {
            System.err.println("❌ [FCM Service] Error: " + e.getMessage());
            e.printStackTrace();
        }
    }

    private void showEmergencyNotification(String title, String body, String payload, String rideId) {
        try {
            NotificationManager notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);

            // ✅ Intent لفتح التطبيق مع تمرير rideId
            Intent intent = new Intent(this, MainActivity.class);
            intent.setAction("OPEN_RIDE_REQUEST");
            intent.putExtra("payload", payload);
            intent.putExtra("ride_id", rideId);
            intent.putExtra("type", "RIDE_REQUEST");
            intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);

            PendingIntent pendingIntent = PendingIntent.getActivity(
                this,
                (int) System.currentTimeMillis(),
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
            System.out.println("✅ [FCM Service] With rideId: " + rideId);

        } catch (Exception e) {
            System.err.println("❌ [FCM Service] Error showing emergency notification: " + e.getMessage());
            e.printStackTrace();
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
            e.printStackTrace();
        }
    }
}