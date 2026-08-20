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

    private static final String CHANNEL_ID = "emergency_channel_v16";

    @Override
    public void onMessageReceived(RemoteMessage message) {
        super.onMessageReceived(message);

        try {
            if (message.getData() == null || message.getData().isEmpty()) {
                return;
            }

            String type = message.getData().get("type");

            if ("RIDE_REQUEST".equals(type)) {
                String rideId = message.getData().get("ride_id");
                String customerName = message.getData().get("customer_name");
                String amount = message.getData().get("amount");
                String vehicleType = message.getData().get("vehicle_type");

                System.out.println("==========================================");
                System.out.println("📱 [FCM Service] RIDE_REQUEST");
                System.out.println("📱 Ride ID: " + rideId);
                System.out.println("📱 Customer: " + customerName);
                System.out.println("📱 Amount: " + amount);
                System.out.println("==========================================");

                if (rideId == null || rideId.isEmpty()) {
                    System.out.println("❌ Missing ride_id");
                    return;
                }

                JSONObject payload = new JSONObject();
                payload.put("ride_id", rideId);
                payload.put("type", "RIDE_REQUEST");
                payload.put("customer_name", customerName != null ? customerName : "عميل");
                payload.put("amount", amount != null ? amount : "0");
                payload.put("vehicle_type", vehicleType != null ? vehicleType : "");

                String payloadString = payload.toString();

                // ✅ حفظ آخر طلب رحلة
                SharedPreferences prefs = getSharedPreferences("notification_data", MODE_PRIVATE);
                prefs.edit()
                    .putString("pending_payload", payloadString)
                    .putString("pending_ride_id", rideId)
                    .putLong("pending_timestamp", System.currentTimeMillis())
                    .apply();

                System.out.println("✅ [FCM Service] Saved to SharedPreferences: " + payloadString);

                // ✅ إنشاء إشعار Native
                showRideNotification(rideId, customerName, amount, payloadString);
                return;
            }

            // ✅ بقية أنواع FCM
            String title = message.getData().get("title");
            if (title == null || title.isEmpty()) {
                title = "تراكا";
            }

            String body = message.getData().get("body");
            if (body == null || body.isEmpty()) {
                body = "لديك إشعار جديد";
            }

            String payload = new JSONObject(message.getData()).toString();
            showNormalNotification(title, body, payload);

        } catch (Exception e) {
            System.err.println("❌ [FCM Service] Error: " + e.getMessage());
            e.printStackTrace();
        }
    }

    private void showRideNotification(String rideId, String customerName, String amount, String payload) {
        try {
            NotificationManager notificationManager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);

            // ✅ Intent مباشر إلى MainActivity
            Intent intent = new Intent(this, MainActivity.class);
            intent.setAction("OPEN_RIDE_REQUEST");
            intent.putExtra("type", "RIDE_REQUEST");
            intent.putExtra("ride_id", rideId);
            intent.putExtra("payload", payload);
            intent.addFlags(
                Intent.FLAG_ACTIVITY_CLEAR_TOP |
                Intent.FLAG_ACTIVITY_SINGLE_TOP |
                Intent.FLAG_ACTIVITY_NEW_TASK
            );

            // ✅ ID مختلف لكل رحلة
            int requestCode = rideId.hashCode();

            PendingIntent pendingIntent = PendingIntent.getActivity(
                this,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
            );

            String title = "🚨 طلب رحلة جديد";
            String body = (customerName != null ? customerName : "عميل") + " - " + (amount != null ? amount : "0") + " SDG";

            NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(new NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setOngoing(false)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent);

            // ✅ صوت
            int soundResId = getResources().getIdentifier("ride_request_sound", "raw", getPackageName());
            if (soundResId > 0) {
                builder.setSound(Uri.parse("android.resource://" + getPackageName() + "/raw/ride_request_sound"));
            }

            // ✅ اهتزاز
            builder.setVibrate(new long[]{0, 500, 300, 500, 300, 500, 300, 500, 300, 500, 300, 500});

            // ✅ Notification ID خاص بالرحلة
            int notificationId = rideId.hashCode();
            notificationManager.notify(notificationId, builder.build());

            System.out.println("✅ [FCM Service] Native RIDE_REQUEST notification shown with ID: " + notificationId);

        } catch (Exception e) {
            System.err.println("❌ Error showing ride notification: " + e.getMessage());
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

            System.out.println("✅ [FCM Service] Normal notification shown: " + title);

        } catch (Exception e) {
            System.err.println("❌ [FCM Service] Error showing normal notification: " + e.getMessage());
            e.printStackTrace();
        }
    }
}