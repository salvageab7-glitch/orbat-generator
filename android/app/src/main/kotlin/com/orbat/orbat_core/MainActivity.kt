package com.orbat.orbat_core

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/// Android native bridges:
/// - orbat/storage: shared Download handoff and a pending plugin RUN intent.
/// - orbat/secret: API-key encryption using an Android Keystore AES-GCM key.
/// The exported RUN action is honored by Dart only after the user selected Agent mode.
class MainActivity : FlutterActivity() {
    private val storageChannelName = "orbat/storage"
    private val secretChannelName = "orbat/secret"
    private var storageChannel: MethodChannel? = null
    private var pendingPluginRun = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        storageChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannelName)
        storageChannel?.setMethodCallHandler { call, result ->
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, secretChannelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "seal" -> {
                            val plain = call.argument<String>("plain")
                                ?: throw IllegalArgumentException("Missing plaintext")
                            result.success(encryptSecret(plain))
                        }
                        "open" -> {
                            val payload = call.argument<String>("payload")
                                ?: throw IllegalArgumentException("Missing ciphertext")
                            result.success(decryptSecret(payload))
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    // Do not include key material or ciphertext in platform errors/logs.
                    result.error("SECRET_STORE", "Android Keystore operation failed", null)
                }
            }

        // Cold-start RUN intents arrive before Dart registers its handler.
        if (intent?.action == PluginRunAction) {
            pendingPluginRun = true
            intent.action = Intent.ACTION_MAIN
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == PluginRunAction) {
            storageChannel?.invokeMethod("pluginRun", null)
                ?: run { pendingPluginRun = true }
        }
    }

    private fun encryptSecret(plain: String): String {
        require(Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            "Android Keystore AES-GCM requires API 23 or newer"
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateSecretKey())
        val encrypted = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        val combined = cipher.iv + encrypted
        return Base64.encodeToString(combined, Base64.NO_WRAP)
    }

    private fun decryptSecret(payload: String): String {
        require(Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            "Android Keystore AES-GCM requires API 23 or newer"
        }
        val combined = Base64.decode(payload, Base64.DEFAULT)
        require(combined.size > GCM_IV_BYTES + GCM_TAG_BYTES) { "Invalid ciphertext" }
        val iv = combined.copyOfRange(0, GCM_IV_BYTES)
        val encrypted = combined.copyOfRange(GCM_IV_BYTES, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            getOrCreateSecretKey(),
            GCMParameterSpec(GCM_TAG_BITS, iv)
        )
        return String(cipher.doFinal(encrypted), Charsets.UTF_8)
    }

    private fun getOrCreateSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existing = keyStore.getKey(SECRET_KEY_ALIAS, null) as? SecretKey
        if (existing != null) return existing

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                SECRET_KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return generator.generateKey()
    }

    companion object {
        const val PluginRunAction = "com.orbat.orbat_core.plugin.RUN"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val SECRET_KEY_ALIAS = "orbat_api_key_v1"
        private const val GCM_IV_BYTES = 12
        private const val GCM_TAG_BITS = 128
        private const val GCM_TAG_BYTES = GCM_TAG_BITS / 8
    }
}
