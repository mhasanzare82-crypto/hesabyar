package com.hesabyar.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "hesabyar/sms"
    private var channel: MethodChannel? = null
    private val permissionRequestCode = 7712
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasSmsPermission" -> result.success(hasSmsPermission())
                "requestSmsPermission" -> {
                    if (hasSmsPermission()) {
                        result.success(mapOf("granted" to true, "canAskAgain" to true))
                    } else if (pendingPermissionResult != null) {
                        result.error("PERMISSION_REQUEST_IN_PROGRESS", "درخواست مجوز پیامک در حال انجام است", null)
                    } else {
                        pendingPermissionResult = result
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.RECEIVE_SMS),
                            permissionRequestCode
                        )
                    }
                }
                "openAppSettings" -> {
                    val intent = android.content.Intent(
                        android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        android.net.Uri.fromParts("package", packageName, null)
                    )
                    startActivity(intent)
                    result.success(true)
                }
                "setSmsConfig" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val senders = call.argument<List<String>>("senders") ?: emptyList()
                    if (enabled && !hasSmsPermission()) {
                        result.error("PERMISSION_REQUIRED", "مجوز دریافت پیامک داده نشده است", null)
                    } else {
                        val prefs = getSharedPreferences(SmsReceiver.PREFS, Context.MODE_PRIVATE)
                        val wasEnabled = prefs.getBoolean("enabled", false)
                        val editor = prefs.edit()
                            .putBoolean("enabled", enabled)
                            .putStringSet("senders", senders.toSet())
                        if (enabled && !wasEnabled) {
                            // Only accept messages received after the user enables monitoring.
                            editor.putLong("activatedAt", System.currentTimeMillis())
                                .putString("pending", "[]")
                        }
                        editor.apply()
                        result.success(true)
                    }
                }
                "getSmsConfig" -> {
                    val prefs = getSharedPreferences(SmsReceiver.PREFS, Context.MODE_PRIVATE)
                    result.success(mapOf(
                        "enabled" to prefs.getBoolean("enabled", false),
                        "senders" to (prefs.getStringSet("senders", emptySet())?.toList() ?: emptyList<String>())
                    ))
                }
                "getPendingSms" -> {
                    val prefs = getSharedPreferences(SmsReceiver.PREFS, Context.MODE_PRIVATE)
                    val raw = prefs.getString("pending", "[]") ?: "[]"
                    result.success(org.json.JSONArray(raw).let { array ->
                        (0 until array.length()).map { i ->
                            val item = array.getJSONObject(i)
                            mapOf(
                                "sender" to item.optString("sender"),
                                "body" to item.optString("body"),
                                "timestamp" to item.optLong("timestamp")
                            )
                        }
                    })
                }
                "clearPendingSms" -> {
                    getSharedPreferences(SmsReceiver.PREFS, Context.MODE_PRIVATE)
                        .edit().putString("pending", "[]").apply()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != permissionRequestCode) return

        val granted = hasSmsPermission()
        val canAskAgain = !granted &&
            ActivityCompat.shouldShowRequestPermissionRationale(
                this,
                Manifest.permission.RECEIVE_SMS
            )
        pendingPermissionResult?.success(
            mapOf("granted" to granted, "canAskAgain" to canAskAgain)
        )
        pendingPermissionResult = null
    }

    private fun hasSmsPermission(): Boolean =
        Build.VERSION.SDK_INT < 23 ||
            checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED
}
