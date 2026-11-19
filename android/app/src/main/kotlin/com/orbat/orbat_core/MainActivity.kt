package com.orbat.orbat_core

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// 插件交接模式（安卓端 Agent 外挂）：
/// - orbat/storage 通道：
///   · isManageStorageGranted / requestManageStorage：所有文件访问授权
///   · consumePendingRun：Dart 就绪后取走「App 未就绪时收到的触发」
/// - Agent 可用 intent 直接触发批处理，无需人工点界面：
///   am start -a com.orbat.orbat_core.plugin.RUN
class MainActivity : FlutterActivity() {
    private val channelName = "orbat/storage"
    private var channel: MethodChannel? = null
    private var pendingPluginRun = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isManageStorageGranted" -> {
                    result.success(
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                            Environment.isExternalStorageManager()
                        else true
                    )
                }
                "requestManageStorage" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        try {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INTENT", e.message, null)
                        }
                    } else result.success(true)
                }
                "consumePendingRun" -> {
                    result.success(pendingPluginRun)
                    pendingPluginRun = false
                }
                else -> result.notImplemented()
            }
        }
        // 冷启动自带触发 intent：Dart 尚未就绪，先记下，等 Dart 拉取
        if (intent?.action == PluginRunAction) pendingPluginRun = true
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == PluginRunAction) {
            // 热触发：Dart 已就绪，直接通知；未就绪则挂起
            channel?.invokeMethod("pluginRun", null)
                ?: run { pendingPluginRun = true }
        }
    }

    companion object {
        const val PluginRunAction = "com.orbat.orbat_core.plugin.RUN"
    }
}
