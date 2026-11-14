package com.hesabyar.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import org.json.JSONArray
import org.json.JSONObject

class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean("enabled", false)) return

        val allowed = prefs.getStringSet("senders", emptySet()) ?: emptySet()
        if (allowed.isEmpty()) return

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        val existing = try { JSONArray(prefs.getString("pending", "[]")) } catch (_: Exception) { JSONArray() }
        val cutoff = prefs.getLong("activatedAt", System.currentTimeMillis())
        messages.forEach { message ->
            val sender = message.originatingAddress ?: return@forEach
            val timestamp = message.timestampMillis
            if (timestamp < cutoff || allowed.none { sender.contains(it, ignoreCase = true) }) return@forEach
            val body = message.messageBody ?: return@forEach
            val item = JSONObject()
                .put("sender", sender)
                .put("body", body)
                .put("timestamp", timestamp)
            existing.put(item)
        }
        val trimmed = JSONArray()
        val start = (existing.length() - MAX_PENDING).coerceAtLeast(0)
        for (i in start until existing.length()) trimmed.put(existing.getJSONObject(i))
        prefs.edit().putString("pending", trimmed.toString()).apply()
    }

    companion object {
        const val PREFS = "hesabyar_sms"
        private const val MAX_PENDING = 100
    }
}
