package com.hesabyar.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import io.flutter.plugin.common.EventChannel

/**
 * Thin Android entry point: validate the broadcast, persist it, then notify
 * an already-running Flutter engine. The persistent queue remains the source
 * of truth when Flutter is not running.
 */
object SmsEventBus {
    @Volatile
    var sink: EventChannel.EventSink? = null

    fun emit() {
        Handler(Looper.getMainLooper()).post { sink?.success(true) }
    }
}

class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val messages = try {
            Telephony.Sms.Intents.getMessagesFromIntent(intent).toList()
        } catch (_: Exception) {
            emptyList()
        }
        if (messages.isEmpty()) return

        if (SmsInboxStore.enqueue(context, messages)) {
            SmsEventBus.emit()
        }
    }
}
