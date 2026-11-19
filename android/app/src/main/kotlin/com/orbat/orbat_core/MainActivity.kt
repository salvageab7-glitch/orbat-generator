package com.orbat.orbat_core

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// 插件交接模式（安卓端 Agent 外挂）用的存储授权通道：
/// - isManageStorageGranted：是否已获「所有文件访问」权限
/// - requestManageStorage：跳系统授权页（用户点一次允许即可）
/// 有该权限后，App 可直接读写公共 Download 下的交接目录，
/// 手机本机 Agent 写入的 JSON 才能被读取。
class MainActivity : FlutterActivity() {
    private val channelName = "orbat/storage"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
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
                    else -> result.notImplemented()
                }
            }
    }
}
