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
            String type = message.getData().get("type");
            
            // ✅ RIDE_REQUEST: نتعامل معه فقط لتخزين البيانات، ولا ننشئ إشعاراً
            // لأن Firebase سينشئ الإشعار من notification
            if ("RIDE_REQUEST".equals(type)) {
                String rideId = message.getData().get("ride_id");
                String customerName = message.getData().get("customer_name");
                String amount = message.getData().get("amount");
                
                System.out.println("📱 [FCM Service] RIDE_REQUEST received (data only)");
                System.out.println("📱 [FCM Service] Ride ID: " + rideId);
                
                // ✅ حفظ البيانات في SharedPreferences كاحتياطي
                if (rideId != null && !rideId.isEmpty()) {
                    JSONObject payload = new JSONObject();
                    payload.put("ride_id", rideId);
                    payload.put("type", "RIDE_REQUEST");
                    payload.put("customer_name", customerName != null ? customerName : "");
                    payload.put("amount", amount != null ? amount : "0");
                    
                    String payloadString = payload.toString();
                    
                    SharedPreferences prefs = getSharedPreferences("notification_data", MODE_PRIVATE);
                    prefs.edit()
                        .putString("pending_payload", payloadString)
                        .putString("pending_ride_id", rideId)
                        .apply();
                    
                    System.out.println("✅ [FCM Service] Data saved to SharedPreferences");
                }
                
                // ✅ لا ننشئ إشعاراً هنا، Firebase سيتعامل معه
                return;
            }
            
            // ✅ الإشعارات الأخرى
            String title = message.getData().get("title") != null ? 
                message.getData().get("title") : "تراكا";
            String body = message.getData().get("body") != null ? 
                message.getData().get("body") : "لديك إشعار جديد";
            String payload = message.getData().toString();
            
            showNormalNotification(title, body, payload);

        } catch (Exception e) {
            System.err.println("❌ [FCM Service] Error: " + e.getMessage());
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