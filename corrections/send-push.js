// ============================================
// SEND-PUSH API - تارحال زونا (النسخة المصححة والمؤمنة)
// إرسال إشعار مباشر للسائق عبر OneSignal
// ============================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// تكوين Supabase - يفضل استخدام متغيرات البيئة لضمان الأمان
const supabaseUrl = process.env.SUPABASE_URL || 'https://zsmlyiygjagmhnglrhoa.supabase.co'
const supabaseKey = process.env.SUPABASE_SERVICE_ROLE_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpzbWx5aXlnamFnbWhuZ2xyaG9hIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjU5NDc3NjMsImV4cCI6MjA4MTUyMzc2M30.QviVinAng-ILq0umvI5UZCFEvNpP3nI0kW_hSaXxNps'
const supabase = createClient(supabaseUrl, supabaseKey)

// إعدادات OneSignal - يجب وضع ONESIGNAL_API_KEY في متغيرات البيئة
const ONESIGNAL_APP_ID = process.env.ONESIGNAL_APP_ID || 'c05c5d16-4e72-4d4a-b1a2-6e7e06232d98'
const ONESIGNAL_API_KEY = process.env.ONESIGNAL_API_KEY // لا تضع المفتاح هنا مباشرة أبداً!

/**
 * إرسال الإشعار باستخدام External User ID
 */
async function sendPushNotification(driverId, rideData) {
    if (!ONESIGNAL_API_KEY) {
        console.error('❌ ONESIGNAL_API_KEY is not defined in environment variables');
        return { success: false, error: 'API Configuration error' };
    }

    try {
        console.log('🚀 إرسال إشعار للسائق (ID):', driverId);

        const notificationData = {
            app_id: ONESIGNAL_APP_ID,
            // ✅ استخدام External User ID بدلاً من Player ID لضمان الموثوقية
            include_external_user_ids: [driverId],
            headings: {
                en: '🎯 New Ride Request',
                ar: '🎯 طلب رحلة جديد'
            },
            contents: {
                en: `New ride from ${rideData.customerName} - ${rideData.amount} SDG`,
                ar: `رحلة جديدة من ${rideData.customerName} - ${rideData.amount} جنيه`
            },
            // ✅ توحيد المفاتيح مع ما يتوقعه تطبيق Flutter
            data: {
                rideId: rideData.rideId,
                requestId: rideData.requestId,
                customerName: rideData.customerName,
                customerPhone: rideData.customerPhone,
                vehicleType: rideData.vehicleType,
                amount: rideData.amount,
                distance: rideData.distance,
                pickupAddress: rideData.pickupAddress,
                destinationAddress: rideData.destinationAddress,
                pickupLat: rideData.pickupLat,
                pickupLng: rideData.pickupLng,
                destinationLat: rideData.destinationLat,
                destinationLng: rideData.destinationLng,
                timestamp: rideData.timestamp,
                type: 'ride_request'
            },
            android_channel_id: 'emergency_channel_v25',
            priority: 10,
            ttl: 60,
            android_visibility: 1,
            ios_sound: 'ride_request_sound.wav',
            android_sound: 'ride_request_sound'
        };

        const response = await fetch('https://onesignal.com/api/v1/notifications', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Basic ${ONESIGNAL_API_KEY}`
            },
            body: JSON.stringify(notificationData)
        });

        const result = await response.json();
        console.log('✅ استجابة OneSignal:', result);

        return {
            success: !!result.id,
            notificationId: result.id,
            errors: result.errors
        };

    } catch (error) {
        console.error('🔥 خطأ في إرسال الإشعار:', error);
        return { success: false, error: error.message };
    }
}

export default async function handler(req, res) {
    if (req.method !== 'POST') return res.status(405).end();

    try {
        const { driverId, rideId } = req.body;

        if (!driverId || !rideId) {
            return res.status(400).json({ success: false, error: 'Missing driverId or rideId' });
        }

        const pushResult = await sendPushNotification(driverId, req.body);

        if (pushResult.success) {
            return res.status(200).json({ success: true, notificationId: pushResult.notificationId });
        } else {
            return res.status(500).json({ success: false, error: pushResult.errors });
        }
    } catch (error) {
        return res.status(500).json({ success: false, error: error.message });
    }
}
