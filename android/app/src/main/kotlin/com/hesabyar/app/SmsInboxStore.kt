package com.hesabyar.app

import android.content.Context
import android.telephony.SmsMessage
import org.json.JSONArray
import org.json.JSONObject

/**
 * Durable, Android-only inbox. The broadcast receiver never calls Flutter;
 * it commits messages here first. Flutter drains the queue through MethodChannel.
 */
object SmsInboxStore {
    const val PREFS = "hesabyar_sms_v2"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_SENDERS = "senders"
    private const val KEY_PENDING = "pending"
    private const val KEY_ACTIVATED_AT = "activatedAt"
    private const val KEY_SEEN = "seen"

    fun prefs(context: Context): android.content.SharedPreferences {
        val app = context.applicationContext
        val current = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!current.getBoolean("migrationDone", false)) {
            val old = app.getSharedPreferences("hesabyar_sms", Context.MODE_PRIVATE)
            val editor = current.edit()
                .putBoolean("migrationDone", true)
                .putBoolean(KEY_ENABLED, old.getBoolean(KEY_ENABLED, false))
                .putStringSet(KEY_SENDERS, old.getStringSet(KEY_SENDERS, emptySet())?.toSet() ?: emptySet())
                .putLong(KEY_ACTIVATED_AT, old.getLong(KEY_ACTIVATED_AT, 0L))
                .putString(KEY_PENDING, old.getString(KEY_PENDING, "[]") ?: "[]")
            editor.commit()
        }
        return current
    }

    fun isEnabled(context: Context) = prefs(context).getBoolean(KEY_ENABLED, false)

    fun senders(context: Context): Set<String> =
        prefs(context).getStringSet(KEY_SENDERS, emptySet())?.toSet() ?: emptySet()

    fun configure(context: Context, enabled: Boolean, senders: List<String>): Boolean {
        val p = prefs(context)
        val wasEnabled = p.getBoolean(KEY_ENABLED, false)
        val editor = p.edit()
            .putBoolean(KEY_ENABLED, enabled)
            .putStringSet(KEY_SENDERS, senders.map { it.trim() }.filter { it.isNotEmpty() }.toSet())
        if (enabled && !wasEnabled) {
            editor.putLong(KEY_ACTIVATED_AT, System.currentTimeMillis())
                .putString(KEY_PENDING, "[]")
                .putString(KEY_SEEN, "[]")
        }
        return editor.commit()
    }

    fun pending(context: Context): JSONArray = try {
        JSONArray(prefs(context).getString(KEY_PENDING, "[]") ?: "[]")
    } catch (_: Exception) {
        JSONArray()
    }

    fun clearPending(context: Context): Boolean =
        prefs(context).edit().putString(KEY_PENDING, "[]").commit()

    fun enqueue(context: Context, messages: List<SmsMessage>): Boolean {
        if (!isEnabled(context)) return false
        val allowed = senders(context)
        if (allowed.isEmpty() || messages.isEmpty()) return false

        val grouped = messages
            .filter { !it.originatingAddress.isNullOrBlank() }
            .groupBy { "${it.originatingAddress}|${it.timestampMillis}" }

        val p = prefs(context)
        val cutoff = p.getLong(KEY_ACTIVATED_AT, 0L)
        val queue = pending(context)
        val seen = try {
            JSONArray(p.getString(KEY_SEEN, "[]") ?: "[]")
        } catch (_: Exception) {
            JSONArray()
        }
        val seenSet = (0 until seen.length()).map { seen.optString(it) }.filter { it.isNotBlank() }.toMutableSet()
        var changed = false

        grouped.values.forEach { parts ->
            val first = parts.first()
            val sender = first.originatingAddress ?: return@forEach
            val timestamp = first.timestampMillis
            if (timestamp < cutoff || allowed.none { matchesSender(sender, it) }) return@forEach

            val body = parts.joinToString("") { it.messageBody.orEmpty() }
            if (body.isBlank()) return@forEach
            val id = "${sender}|${timestamp}|${body.hashCode()}"
            if (!seenSet.add(id)) return@forEach

            queue.put(
                JSONObject()
                    .put("id", id)
                    .put("sender", sender)
                    .put("body", body)
                    .put("timestamp", timestamp)
            )
            changed = true
        }

        if (!changed) return false

        val boundedQueue = JSONArray()
        val queueStart = (queue.length() - 200).coerceAtLeast(0)
        for (i in queueStart until queue.length()) boundedQueue.put(queue.getJSONObject(i))

        val boundedSeen = JSONArray()
        seenSet.takeLast(500).forEach { boundedSeen.put(it) }

        // A synchronous commit is intentional: the SMS broadcast may be the
        // only process execution we get before Android kills the receiver.
        val committed = p.edit()
            .putString(KEY_PENDING, boundedQueue.toString())
            .putString(KEY_SEEN, boundedSeen.toString())
            .commit()
        return committed
    }

    private fun matchesSender(actual: String, configured: String): Boolean {
        val a = normalize(actual)
        val c = normalize(configured)
        if (a.isNotEmpty() && c.isNotEmpty()) return a == c
        return actual.trim().equals(configured.trim(), ignoreCase = true)
    }

    private fun normalize(value: String): String {
        val digits = value.mapNotNull { ch ->
            when (ch) {
                in '0'..'9' -> ch
                in '۰'..'۹' -> ('0'.code + ch.code - '۰'.code).toChar()
                in '٠'..'٩' -> ('0'.code + ch.code - '٠'.code).toChar()
                else -> null
            }
        }.joinToString("")
        return when {
            digits.startsWith("0098") && digits.length > 4 -> "0" + digits.drop(4)
            digits.startsWith("98") && digits.length > 2 -> "0" + digits.drop(2)
            else -> digits
        }
    }
}
