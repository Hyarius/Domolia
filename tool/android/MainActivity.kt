package fr.domolia.domolia

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import androidx.core.content.ContextCompat
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "domolia/updates"

    private val permissionRequest = 4901
    private var pendingApk: File? = null
    private var installResult: MethodChannel.Result? = null
    private var receiver: BroadcastReceiver? = null
    private var confirmation: Intent? = null
    private var foreground = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        // Native Context.getFilesDir, same location used by
                        // path_provider's application support directory.
                        // Avoids the JNI class lookup used by recent versions
                        // of path_provider_android on release builds.
                        "applicationSupportPath" -> {
                            result.success(applicationContext.filesDir.absolutePath)
                        }
                        "installedApp" -> {
                            val info = packageInfo(packageName, 0)
                            val code = versionCode(info)
                            // Once an update is installed, its private APK copy can be released.
                            val filename = Regex("""update-(\d+)\.apk""")
                            File(filesDir, "updates").listFiles()?.forEach { file ->
                                val build = filename.matchEntire(file.name)?.groupValues?.get(1)?.toLongOrNull()
                                if (build != null && build <= code && file.isFile) file.delete()
                            }
                            result.success(
                                mapOf(
                                    "packageName" to packageName,
                                    "versionName" to (info.versionName ?: ""),
                                    "versionCode" to code
                                )
                            )
                        }
                        "installApk" -> {
                            val path = call.argument<String>("path")
                                ?: throw IllegalArgumentException("Chemin APK absent.")
                            requestUpdate(path, result)
                        }
                        else -> result.notImplemented()
                    }
                } catch (exception: Exception) {
                    result.error("ANDROID_UPDATE", exception.message, null)
                }
            }
    }

    private fun packageInfo(name: String, flags: Int): PackageInfo =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(name, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(name, flags)
        }

    private fun archiveInfo(path: String, flags: Int): PackageInfo? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageArchiveInfo(path, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageArchiveInfo(path, flags)
        }

    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
        else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }

    private fun requestUpdate(path: String, result: MethodChannel.Result) {
        check(installResult == null) { "Une installation est déjà en cours." }
        // Do not let Dart pass arbitrary files to FileProvider.
        val updatesDir = File(filesDir, "updates").canonicalFile
        val apk = File(path).canonicalFile
        require(apk.parentFile == updatesDir)
        require(apk.name.matches(Regex("update-[0-9]+\\.apk")))
        require(apk.isFile && apk.length() > 0) { "APK introuvable." }

        installResult = result
        pendingApk = apk
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()) {
                startActivityForResult(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")), permissionRequest)
            } else {
                prepareUpdate(apk)
            }
        } catch (error: Exception) {
            finishUpdate(error = error)
        }
    }

    @Deprecated("Used for Android's per-source installation permission")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != permissionRequest) return
        val apk = pendingApk ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()) {
            finishUpdate("permissionRequired")
        } else {
            prepareUpdate(apk)
        }
    }

    private fun validateArchive(apk: File) {
        // PackageInstaller authenticates the replacement against the installed signer
        // (including valid key rotations). Archive signingInfo can be null on Android 13.
        val archive = archiveInfo(apk.path, 0)
            ?: throw IllegalArgumentException("APK Android invalide.")
        require(archive.packageName == packageName) { "Identifiant Android différent." }
        require(versionCode(archive) > versionCode(packageInfo(packageName, 0))) {
            "Version Android non supérieure."
        }
    }

    // Reading and staging the APK can take seconds on a phone.
    private fun prepareUpdate(apk: File) {
        Thread {
            var sessionId: Int? = null
            try {
                validateArchive(apk)
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                    val uri = FileProvider.getUriForFile(this, "$packageName.updates.fileprovider", apk)
                    val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    runOnUiThread { showConfirmation(intent) }
                    return@Thread
                }
                val installer = packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                    setAppPackageName(packageName)
                    setSize(apk.length())
                    setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                }
                val id = installer.createSession(params)
                sessionId = id
                installer.openSession(id).use { session ->
                    session.openWrite("base.apk", 0, apk.length()).use { output ->
                        apk.inputStream().use { it.copyTo(output) }
                        session.fsync(output)
                    }
                }
                runOnUiThread { commitUpdate(installer, id) }
            } catch (error: Exception) {
                sessionId?.let { runCatching { packageManager.packageInstaller.abandonSession(it) } }
                runOnUiThread { finishUpdate(error = error) }
            }
        }.start()
    }

    private fun commitUpdate(installer: PackageInstaller, id: Int) {
        if (installResult == null) {
            runCatching { installer.abandonSession(id) }
            return
        }
        try {
            val action = "$packageName.UPDATE_RESULT.$id"
            val listener = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    if (intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1) != id) return
                    when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                        PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                            @Suppress("DEPRECATION")
                            val prompt = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                            if (prompt == null) finishUpdate(error = IllegalStateException("Confirmation Android absente."))
                            else showConfirmation(prompt)
                        }
                        PackageInstaller.STATUS_SUCCESS -> finishUpdate("installed")
                        PackageInstaller.STATUS_FAILURE_ABORTED -> finishUpdate("cancelled")
                        else -> finishUpdate(error = IllegalStateException(
                            intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "Installation refusée par Android."))
                    }
                }
            }
            ContextCompat.registerReceiver(this, listener, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)
            receiver = listener
            val callback = PendingIntent.getBroadcast(this, id, Intent(action).setPackage(packageName),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            installer.openSession(id).use { it.commit(callback.intentSender) }
        } catch (error: Exception) {
            runCatching { installer.abandonSession(id) }
            finishUpdate(error = error)
        }
    }

    private fun showConfirmation(intent: Intent) {
        if (installResult == null) return
        if (!foreground) {
            confirmation = intent
            return
        }
        try {
            startActivity(intent)
            // The legacy system installer has no status callback.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) finishUpdate("launched")
        } catch (error: Exception) {
            finishUpdate(error = error)
        }
    }

    override fun onPostResume() {
        super.onPostResume()
        foreground = true
        val intent = confirmation ?: return
        confirmation = null
        showConfirmation(intent)
    }

    override fun onPause() {
        foreground = false
        super.onPause()
    }

    private fun finishUpdate(status: String? = null, error: Exception? = null) {
        receiver?.let { unregisterReceiver(it) }
        receiver = null
        pendingApk = null
        confirmation = null
        val result = installResult
        installResult = null
        if (error == null) result?.success(status) else result?.error("ANDROID_UPDATE", error.message, null)
    }

    override fun onDestroy() {
        finishUpdate("cancelled")
        super.onDestroy()
    }
}
