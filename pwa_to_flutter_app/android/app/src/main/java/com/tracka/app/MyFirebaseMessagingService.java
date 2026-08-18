package com.tracka.app;

import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import androidx.core.app.NotificationCompat;
import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;
import org.json.JSONObject;

public class MyFirebaseMessagingService extends FirebaseMessagingService {

    @Override
    public void onMessageReceived(RemoteMessage message) {
        super.onMessageReceived(message);

        try {
            // ✅ استخراج البيانات من data فقط
            String type = message.getData().get("type");
            String rideId = message.getData().get("ride_id");
            String customerName = message.getData().get("customer_name");
            String amount = message.getData().get("amount");
            String vehicleType = message.getData().get("vehicle_type");
            
            System.out.println("📱 [FCM Service] ==============================");
            System.out.println("📱 [FCM Service] Type: " + type);
            System.out.println("📱 [FCM Service] Ride ID: " + rideId);
            System.out.println("📱 [FCM Service] Customer: " + customerName);
            System.out.println("📱 [FCM Service] Amount: " + amount);
            System.out.println("📱 [FCM Service] ==============================");

            // ✅ بناء payload كـ JSON كامل
            JSONObject payload = new JSONObject();
            payload.put("ride_id", rideId != null ? rideId : "");
            payload.put("type", type != null ? type : "RIDE_REQUEST");
            payload.put("customer_name", customerName != null ? customerName : "");
            payload.put("amount", amount != null ? amount : "0");
            payload.put("vehicle_type", vehicleType != null ? vehicleType : "");
            
            String payloadString = payload.toString();

            // ✅ حفظ البيانات في SharedPreferences للتأكد من وصولها
            SharedPreferences prefs = getSharedPreferences("notification_data", MODE_PRIVATE);
            prefs.edit()
                .putString("pending_payload", payloadString)
                .putString("pending_ride_id", rideId)
                .putString("pending_type", type)
                .apply();
            
            System.out.println("✅ [FCM Service] Data saved to SharedPreferences");
            System.out.println("✅ [FCM Service] Payload: " + payloadString);

            // ✅ إذا كان RIDE_REQUEST، اعرض إشعار الطوارئ
            if ("RIDE_REQUEST".equals(type)) {
                String title = "🚨 طلب رحلة جديد";
                String body = customerName + " - " + amount + " SDG";
                showEmergencyNotification(title, body, payloadString, rideId);
            } else {
                // إشعار عادي
                String title = message.getData().get("title") != null ? 
                    message.getData().get("title") : "تراكا";
                String body = message.getData().get("body") != null ? 
                    message.getData().get("body") : "لديك إشعار جديد";
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

            // ✅ Intent مع جميع البيانات
            Intent intent = new Intent(this, MainActivity.class);
            intent.setAction("OPEN_RIDE_REQUEST");
            intent.putExtra("payload", payload);
            intent.putExtra("ride_id", rideId != null ? rideId : "");
            intent.putExtra("type", "RIDE_REQUEST");
            
            // ✅ استخراج بيانات إضافية من payload
            try {
                JSONObject json = new JSONObject(payload);
                intent.putExtra("customer_name", json.optString("customer_name", ""));
                intent.putExtra("amount", json.optString("amount", "0"));
                intent.putExtra("vehicle_type", json.optString("vehicle_type", ""));
            } catch (Exception e) {
                System.err.println("⚠️ Could not parse payload extras");
            }
            
            intent.setFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK |
                Intent.FLAG_ACTIVITY_CLEAR_TOP |
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            );

            // ✅ استخدام rideId كـ requestCode لتجنب تكرار الـ PendingIntent
            int requestCode = rideId != null ? rideId.hashCode() : (int) System.currentTimeMillis();
            
            PendingIntent pendingIntent = PendingIntent.getActivity(
                this,
                requestCode,
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

            // ✅ إضافة الصوت
            try {
                int soundResId = getResources().getIdentifier("ride_request_sound", "raw", getPackageName());
                if (soundResId > 0) {
                    notification.setSound(android.net.Uri.parse("android.resource://" + getPackageName() + "/raw/ride_request_sound"));
                }
            } catch (Exception e) {
                System.err.println("⚠️ Sound resource not found");
            }

            int notificationId = (int) System.currentTimeMillis();
            notificationManager.notify(notificationId, notification.build());

            System.out.println("✅ [FCM Service] Emergency notification shown");
            System.out.println("✅ [FCM Service] ride_id: " + rideId);

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
            intent.setFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK |
                Intent.FLAG_ACTIVITY_CLEAR_TOP |
                Intent.FLAG_ACTIVITY_SINGLE_TOP
            );

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

            System.out.println("✅ [FCM Service] Normal notification shown");

        } catch (Exception e) {
            System.err.println("❌ [FCM Service] Error showing normal notification: " + e.getMessage());
            e.printStackTrace();
        }
    }
}