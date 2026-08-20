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
import androidx.core.app.NotificationCompat;
import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;
import org.json.JSONObject;

public class MyFirebaseMessagingService extends FirebaseMessagingService {
    private static final String EMERGENCY_CHANNEL_ID = "emergency_channel_v16";

    @Override
    public void onMessageReceived(RemoteMessage message) {
        super.onMessageReceived(message);

        try {
            System.out.println("📱 [FCM Service] =================================");
            System.out.println("📱 [FCM Service] Message received");
            System.out.println("📱 [FCM Service] Data: " + message.getData());
            System.out.println("📱 [FCM Service] =================================");

            String type = message.getData().get("type");

            if ("RIDE_REQUEST".equals(type)) {
                handleRideRequest(message);
                return;
            }

            // باقي الإشعارات
            String title = message.getData().get("title");
            String body = message.getData().get("body");
            if (title == null || title.isEmpty()) {
                title = "تراكا";
            }
            if (body == null || body.isEmpty()) {
                body = "لديك إشعار جديد";
            }
            showNormalNotification(title, body, message.getData().toString());

        } catch (Exception e) {
            System.err.println("❌ [FCM Service] Error: " + e.getMessage());
            e.printStackTrace();
        }
    }

    private void handleRideRequest(RemoteMessage message) {
        try {
            String rideId = message.getData().get("ride_id");
            String customerName = message.getData().get("customer_name");
            String amount = message.getData().get("amount");
            String vehicleType = message.getData().get("vehicle_type");

            if (rideId == null || rideId.isEmpty()) {
                System.err.println("❌ [FCM Service] RIDE_REQUEST without ride_id");
                return;
            }

            if (customerName == null) {
                customerName = "عميل";
            }
            if (amount == null) {
                amount = "0";
            }
            if (vehicleType == null) {
                vehicleType = "";
            }

            // ✅ إنشاء payload كامل
            JSONObject payload = new JSONObject();
            payload.put("ride_id", rideId);
            payload.put("type", "RIDE_REQUEST");
            payload.put("customer_name", customerName);
            payload.put("amount", amount);
            payload.put("vehicle_type", vehicleType);

            String payloadString = payload.toString();

            // ✅ حفظ البيانات في SharedPreferences
            SharedPreferences prefs = getSharedPreferences("notification_data", MODE_PRIVATE);
            prefs.edit()
                .putString("pending_payload", payloadString)
                .putString("pending_ride_id", rideId)
                .putLong("pending_timestamp", System.currentTimeMillis())
                .apply();

            System.out.println("✅ [FCM Service] Ride payload saved: " + payloadString);

            // ✅ إنشاء قناة الإشعار
            createEmergencyChannel();

            // ✅ Intent مباشر إلى MainActivity
            Intent intent = new Intent(this, MainActivity.class);
            intent.setAction("OPEN_RIDE_REQUEST");
            intent.putExtra("payload", payloadString);
            intent.putExtra("ride_id", rideId);
            intent.putExtra("type", "RIDE_REQUEST");
            intent.addFlags(
                Intent.FLAG_ACTIVITY_CLEAR_TOP |
                Intent.FLAG_ACTIVITY_SINGLE_TOP |
                Intent.FLAG_ACTIVITY_NEW_TASK
            );

            // requestCode مختلف لكل رحلة
            int requestCode = rideId.hashCode();

            PendingIntent pendingIntent = PendingIntent.getActivity(
                this,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
            );

            String title = "🚨 طلب رحلة جديد";
            String body = customerName + " - " + amount + " SDG";

            NotificationCompat.Builder notification = new NotificationCompat.Builder(this, EMERGENCY_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(new NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setAutoCancel(false)
                .setOngoing(true)
                .setContentIntent(pendingIntent);

            // ✅ إضافة الصوت
            try {
                int soundResId = getResources().getIdentifier("ride_request_sound", "raw", getPackageName());
                if (soundResId > 0) {
                    notification.setSound(Uri.parse("android.resource://" + getPackageName() + "/raw/ride_request_sound"));
                }
            } catch (Exception e) {
                System.err.println("⚠️ Sound resource not found");
            }

            // ✅ إضافة الاهتزاز
            notification.setVibrate(new long[]{0, 500, 300, 500, 300, 500, 300, 500, 300, 500, 300, 500});

            NotificationManager notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            notificationManager.notify(requestCode, notification.build());

            System.out.println("✅ [FCM Service] RIDE_REQUEST notification displayed");

        } catch (Exception e) {
            System.err.println("❌ [FCM Service] handleRideRequest error: " + e.getMessage());
            e.printStackTrace();
        }
    }

    private void createEmergencyChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager manager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);

            NotificationChannel channel = new NotificationChannel(
                EMERGENCY_CHANNEL_ID,
                "تنبيهات الطوارئ - تراكا",
                NotificationManager.IMPORTANCE_MAX
            );
            channel.setDescription("تنبيهات طلبات الرحلات الجديدة");
            channel.enableVibration(true);
            channel.setVibrationPattern(new long[]{0, 500, 300, 500, 300, 500, 300, 500});
            channel.setLockscreenVisibility(NotificationCompat.VISIBILITY_PUBLIC);

            // ✅ إضافة الصوت للقناة
            try {
                int soundResId = getResources().getIdentifier("ride_request_sound", "raw", getPackageName());
                if (soundResId > 0) {
                    Uri soundUri = Uri.parse("android.resource://" + getPackageName() + "/raw/ride_request_sound");
                    AudioAttributes audioAttributes = new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build();
                    channel.setSound(soundUri, audioAttributes);
                }
            } catch (Exception e) {
                System.err.println("⚠️ Sound resource not found for channel");
            }

            manager.createNotificationChannel(channel);
            System.out.println("✅ [FCM Service] Emergency channel created: " + EMERGENCY_CHANNEL_ID);
        }
    }

    private void showNormalNotification(String title, String body, String payload) {
        try {
            NotificationManager notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);

            Intent intent = new Intent(this, MainActivity.class);
            intent.setAction("OPEN_NORMAL_NOTIFICATION");
            intent.putExtra("payload", payload);
            intent.addFlags(
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

            System.out.println("✅ [FCM Service] Normal notification shown: " + title);

        } catch (Exception e) {
            System.err.println("❌ [FCM Service] Normal notification error: " + e.getMessage());
            e.printStackTrace();
        }
    }
}