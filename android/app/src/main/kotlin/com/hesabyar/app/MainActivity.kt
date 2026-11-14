package com.hesabyar.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "hesabyar/sms"
    private val eventChannelName = "hesabyar/sms_events"
    private val permissionRequestCode = 7712
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    SmsEventBus.sink = events
                }

                override fun onCancel(arguments: Any?) {
                    SmsEventBus.sink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasSmsPermission" -> result.success(hasSmsPermission())
                    "requestSmsPermission" -> requestSmsPermission(result)
                    "openAppSettings" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.fromParts("package", packageName, null)
                            )
                        )
                        result.success(true)
                    }
                    "setSmsConfig" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val senders = call.argument<List<String>>("senders") ?: emptyList()
                        if (enabled && !hasSmsPermission()) {
                            result.error("PERMISSION_REQUIRED", "مجوز دریافت پیامک داده نشده است", null)
                        } else if (enabled && senders.isEmpty()) {
                            result.error("SENDER_REQUIRED", "حداقل یک فرستنده باید انتخاب شود", null)
                        } else {
                            result.success(SmsInboxStore.configure(this, enabled, senders))
                        }
                    }
                    "getSmsConfig" -> result.success(
                        mapOf(
                            "enabled" to SmsInboxStore.isEnabled(this),
                            "senders" to SmsInboxStore.senders(this).toList()
                        )
                    )
                    "getPendingSms" -> {
                        val queue = SmsInboxStore.pending(this)
                        result.success((0 until queue.length()).map { index ->
                            val item = queue.getJSONObject(index)
                            mapOf(
                                "id" to item.optString("id"),
                                "sender" to item.optString("sender"),
                                "body" to item.optString("body"),
                                "timestamp" to item.optLong("timestamp")
                            )
                        })
                    }
                    "clearPendingSms" -> result.success(SmsInboxStore.clearPending(this))
                    "ackPendingSms" -> {
                        val ids = call.argument<List<String>>("ids")?.toSet() ?: emptySet()
                        result.success(SmsInboxStore.acknowledge(this, ids))
                    }
                    "getSmsDiagnostics" -> result.success(
                        mapOf(
                            "permissionGranted" to hasSmsPermission(),
                            "monitoringEnabled" to SmsInboxStore.isEnabled(this),
                            "senderCount" to SmsInboxStore.senders(this).size,
                            "pendingCount" to SmsInboxStore.pending(this).length(),
                            "sdkInt" to Build.VERSION.SDK_INT
                        )
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestSmsPermission(result: MethodChannel.Result) {
        if (hasSmsPermission()) {
            result.success(mapOf("granted" to true, "canAskAgain" to true))
            return
        }
        if (pendingPermissionResult != null) {
            result.error("PERMISSION_REQUEST_IN_PROGRESS", "درخواست مجوز پیامک در حال انجام است", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.RECEIVE_SMS),
            permissionRequestCode
        )
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
