package com.hesabyar.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import io.flutter.plugin.common.EventChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * Process-wide bridge to notify the running Flutter engine that new SMS
 * messages have been persisted. Pending messages are also retained on disk,
 * so delivery still works when the app process is not running.
 */
object SmsEventBus {
    @Volatile
    var sink: EventChannel.EventSink? = null

    fun emit() {
        Handler(Looper.getMainLooper()).post {
            sink?.success(true)
        }
    }
}

class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean("enabled", false)) return

        val allowed = prefs.getStringSet("senders", emptySet()) ?: emptySet()
        if (allowed.isEmpty()) return

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isEmpty()) return

        // A multipart SMS arrives as several SmsMessage PDUs. Join the parts
        // before handing the message to Flutter, otherwise bank texts may be
        // parsed as incomplete fragments.
        val grouped = messages
            .filter { !it.originatingAddress.isNullOrBlank() }
            .groupBy { "${it.originatingAddress}|${it.timestampMillis}" }

        val existing = try {
            JSONArray(prefs.getString("pending", "[]"))
        } catch (_: Exception) {
            JSONArray()
        }
        val cutoff = prefs.getLong("activatedAt", 0L)
        var added = false

        grouped.values.forEach { parts ->
            val first = parts.first()
            val sender = first.originatingAddress ?: return@forEach
            val timestamp = first.timestampMillis
            if (timestamp < cutoff || allowed.none { senderMatches(sender, it) }) {
                return@forEach
            }

            val body = parts.joinToString(separator = "") { it.messageBody.orEmpty() }
            if (body.isBlank()) return@forEach

            // Avoid duplicate insertion if Android redelivers the broadcast.
            val duplicate = (0 until existing.length()).any { index ->
                val item = existing.optJSONObject(index) ?: return@any false
                item.optString("sender") == sender &&
                    item.optLong("timestamp") == timestamp &&
                    item.optString("body") == body
            }
            if (duplicate) return@forEach

            existing.put(
                JSONObject()
                    .put("sender", sender)
                    .put("body", body)
                    .put("timestamp", timestamp)
            )
            added = true
        }

        if (!added) return
        val trimmed = JSONArray()
        val start = (existing.length() - MAX_PENDING).coerceAtLeast(0)
        for (index in start until existing.length()) {
            trimmed.put(existing.getJSONObject(index))
        }

        // commit() ensures the pending queue is durable before notifying UI.
        prefs.edit().putString("pending", trimmed.toString()).commit()
        SmsEventBus.emit()
    }

    private fun senderMatches(actual: String, configured: String): Boolean {
        val actualDigits = normalizePhone(actual)
        val configuredDigits = normalizePhone(configured)

        // Numeric sender IDs (including short codes) are matched by their
        // normalized digits. Alphanumeric sender IDs are matched by text.
        if (actualDigits.isNotEmpty() && configuredDigits.isNotEmpty()) {
            return actualDigits == configuredDigits
        }
        return actual.trim().equals(configured.trim(), ignoreCase = true)
    }

    private fun normalizePhone(value: String): String {
        val digits = value.mapNotNull { char ->
            when (char) {
                in '0'..'9' -> char
                in '۰'..'۹' -> ('0'.code + (char.code - '۰'.code)).toChar()
                in '٠'..'٩' -> ('0'.code + (char.code - '٠'.code)).toChar()
                else -> null
            }
        }.joinToString("")

        return when {
            digits.startsWith("0098") && digits.length > 4 -> "0" + digits.drop(4)
            digits.startsWith("98") && digits.length > 2 -> "0" + digits.drop(2)
            else -> digits
        }
    }

    companion object {
        const val PREFS = "hesabyar_sms"
        private const val MAX_PENDING = 100
    }
}
