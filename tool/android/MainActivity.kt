package fr.domolia.domolia

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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "installedApp" -> {
                            val info = packageInfo(packageName, 0)
                            result.success(
                                mapOf(
                                    "packageName" to packageName,
                                    "versionName" to (info.versionName ?: ""),
                                    "versionCode" to versionCode(info)
                                )
                            )
                        }
                        "installApk" -> {
                            val path = call.argument<String>("path")
                                ?: throw IllegalArgumentException("Chemin APK absent.")
                            result.success(installApk(path))
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

    private fun certificates(info: PackageInfo): Set<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners?.map { it.toCharsString() }?.toSet()
                ?: emptySet()
        } else {
            @Suppress("DEPRECATION")
            info.signatures?.map { it.toCharsString() }?.toSet() ?: emptySet()
        }

    private fun installApk(path: String): String {
        // Do not let Dart pass arbitrary files to FileProvider.
        val updatesDir = File(filesDir, "updates").canonicalFile
        val apk = File(path).canonicalFile
        require(apk.parentFile == updatesDir)
        require(apk.name.matches(Regex("update-[0-9]+\\.apk")))
        require(apk.isFile && apk.length() > 0) { "APK introuvable." }

        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            PackageManager.GET_SIGNING_CERTIFICATES else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        val archive = archiveInfo(apk.path, flags)
            ?: throw IllegalArgumentException("APK Android invalide.")
        require(archive.packageName == packageName) { "Identifiant Android différent." }
        require(versionCode(archive) > versionCode(packageInfo(packageName, 0))) {
            "Version Android non supérieure."
        }
        val installed = packageInfo(packageName, flags)
        require(certificates(installed).isNotEmpty() &&
                certificates(installed) == certificates(archive)) {
            "Signature Android incompatible."
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()) {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName")))
            return "permissionRequired"
        }

        val uri = FileProvider.getUriForFile(
            this, "$packageName.updates.fileprovider", apk
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
        return "launched"
    }
}
