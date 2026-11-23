package com.zephyr.breeze

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Debug
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterFragmentActivity() {
    companion object {
        private const val TAG = "ImpellerConfig"
        private const val IMPELLER_CHANNEL = "impeller_config"
        private const val PREFS_NAME = "flutter_engine_config"
        private const val KEY_FORCE_ENABLE_IMPELLER = "force_enable_impeller"
        private const val COPY_BUFFER_SIZE = 256 * 1024
        private const val COPY_PROGRESS_LOG_STEP = 50L * 1024 * 1024
        private val INVALID_FILE_NAME_CHARS = Regex("[\\\\/:*?\"<>|\\u0000-\\u001f]")

        // 内存采集会做 binder / /proc 读取，统一串行跑在单个后台线程上，
        // 不占用 Android 主线程（MethodChannel 回调默认在主线程执行）。
        // 进程级共享，随进程存活，不需要随 Activity 销毁。
        private val memoryMonitorExecutor: ExecutorService =
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "breeze-memory-monitor").apply { isDaemon = true }
            }

        init {
            System.loadLibrary("windcore")
        }

        @JvmStatic
        private external fun initRustlsPlatformVerifier(context: Context)
    }

    private val CHANNEL = "memory_monitor"
    private val VOLUME_CHANNEL = "volume_key_handler"
    private val VOLUME_EVENT_CHANNEL = "volume_key_events"
    private val SYSTEM_UI_CHANNEL = "system_ui_control"
    private val REALSR_CHANNEL = "realsr_super_resolution"
    private val FILE_PICKER_CHANNEL = "com.zephyr.breeze/file_picker"
    private val REQUEST_CODE_PICK_BACKUP_ZIP = 1001
    private val REQUEST_CODE_PICK_COMIC_ARCHIVE = 1002
    private val REQUEST_CODE_PICK_COMIC_DIRECTORY = 1003

    private var volumeKeyInterceptionEnabled = false
    private var volumeEventSink: EventChannel.EventSink? = null
    private var pendingFilePickerResult: MethodChannel.Result? = null
    private var pendingFilePickerDestPath: String? = null
    private var pendingComicPickerResult: MethodChannel.Result? = null
    private var pendingComicPickerDestDir: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        initRustlsPlatformVerifier(applicationContext)
        super.onCreate(savedInstanceState)
    }

    override fun createFlutterFragment(): FlutterFragment {
        val shellArgs = FlutterShellArgs.fromIntent(intent)
        val forceEnableImpeller = isForceEnableImpeller()

        if (!forceEnableImpeller) {
            shellArgs.add(FlutterShellArgs.ARG_DISABLE_IMPELLER)
            Log.i(TAG, "Impeller is disabled by user setting on this device.")
        }

        if (forceEnableImpeller) {
            Log.i(TAG, "Impeller force-enable switch is ON. Keeping Impeller enabled.")
        }

        return FlutterFragment.withNewEngine()
            .flutterShellArgs(shellArgs)
            .shouldAutomaticallyHandleOnBackPressed(true)
            .build()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getMemoryInfo" -> memoryMonitorExecutor.execute {
                    try {
                        result.success(getMemoryInfo())
                    } catch (e: Exception) {
                        result.error("MEMORY_ERROR", "Failed to get memory info", e.message)
                    }
                }
                "getDartMemoryInfo" -> memoryMonitorExecutor.execute {
                    try {
                        result.success(getDartMemoryInfo())
                    } catch (e: Exception) {
                        result.error("DART_MEMORY_ERROR", "Failed to get Dart memory info", e.message)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // 音量键拦截 MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOLUME_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enableInterception" -> {
                    volumeKeyInterceptionEnabled = true
                    result.success(null)
                }
                "disableInterception" -> {
                    volumeKeyInterceptionEnabled = false
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // 音量键事件 EventChannel
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, VOLUME_EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    volumeEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    volumeEventSink = null
                }
            }
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, IMPELLER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setForceEnableImpeller" -> {
                    val enable = call.argument<Boolean>("enable") ?: false
                    saveForceEnableImpeller(enable)
                    Log.i(TAG, "Updated force enable Impeller: $enable")
                    result.success(null)
                }
                "getForceEnableImpeller" -> {
                    result.success(isForceEnableImpeller())
                }
                "isImpellerForceEnableSupported" -> {
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_UI_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hideSystemBars" -> {
                    setInstantSystemUiVisibility(immersive = true)
                    result.success(null)
                }
                "hideNavigationBarOnly" -> {
                    setNavigationBarOnlyVisibility()
                    result.success(null)
                }
                "showSystemBars" -> {
                    setInstantSystemUiVisibility(immersive = false)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, REALSR_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getWaifu2xCliPath" -> {
                    Thread {
                        try {
                            val nativeLibDir = applicationInfo.nativeLibraryDir
                            val cli = File(nativeLibDir, "libwaifu2x_cli.so")
                            if (!cli.exists()) {
                                runOnUiThread { result.error("CLI_NOT_FOUND", "libwaifu2x_cli.so not found in $nativeLibDir", null) }
                                return@Thread
                            }
                            runOnUiThread { result.success(cli.absolutePath) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("GET_CLI_PATH_ERROR", e.message, e.stackTraceToString()) }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_PICKER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickBackupZip" -> {
                    val destPath = call.argument<String>("destPath")
                    if (destPath == null) {
                        result.error("INVALID_ARGS", "destPath is required", null)
                    } else {
                        pendingFilePickerResult = result
                        pendingFilePickerDestPath = destPath
                        openBackupZipPicker()
                    }
                }
                "pickComicArchive" -> {
                    val destDir = call.argument<String>("destDir")
                    if (destDir == null) {
                        result.error("INVALID_ARGS", "destDir is required", null)
                    } else {
                        pendingComicPickerResult = result
                        pendingComicPickerDestDir = destDir
                        openComicArchivePicker()
                    }
                }
                "pickComicDirectory" -> {
                    val destDir = call.argument<String>("destDir")
                    if (destDir == null) {
                        result.error("INVALID_ARGS", "destDir is required", null)
                    } else {
                        pendingComicPickerResult = result
                        pendingComicPickerDestDir = destDir
                        openComicDirectoryPicker()
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun openBackupZipPicker() {
        Log.i("FilePicker", "打开系统文件选择器")
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/zip"
        }
        try {
            startActivityForResult(intent, REQUEST_CODE_PICK_BACKUP_ZIP)
        } catch (e: Exception) {
            Log.e("FilePicker", "打开选择器失败", e)
            pendingFilePickerResult?.error("PICKER_ERROR", e.message, e.stackTraceToString())
            pendingFilePickerResult = null
            pendingFilePickerDestPath = null
        }
    }

    private fun openComicArchivePicker() {
        Log.i("FilePicker", "打开外部漫画压缩包选择器")
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "application/zip",
                    "application/x-zip-compressed",
                    "application/x-rar-compressed",
                    "application/vnd.rar",
                    "application/x-7z-compressed",
                    "application/x-tar",
                    "application/octet-stream"
                )
            )
        }
        try {
            startActivityForResult(intent, REQUEST_CODE_PICK_COMIC_ARCHIVE)
        } catch (e: Exception) {
            Log.e("FilePicker", "打开压缩包选择器失败", e)
            pendingComicPickerResult?.error("PICKER_ERROR", e.message, e.stackTraceToString())
            pendingComicPickerResult = null
            pendingComicPickerDestDir = null
        }
    }

    private fun openComicDirectoryPicker() {
        Log.i("FilePicker", "打开外部漫画文件夹选择器")
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
        }
        try {
            startActivityForResult(intent, REQUEST_CODE_PICK_COMIC_DIRECTORY)
        } catch (e: Exception) {
            Log.e("FilePicker", "打开文件夹选择器失败", e)
            pendingComicPickerResult?.error("PICKER_ERROR", e.message, e.stackTraceToString())
            pendingComicPickerResult = null
            pendingComicPickerDestDir = null
        }
    }

    private fun copyComicArchive(uri: Uri, destDir: String): Map<String, String> {
        val targetDir = File(destDir)
        targetDir.mkdirs()
        val displayName = sanitizeFileName(queryDisplayName(uri) ?: "comic.cbz")
        val target = File(targetDir, displayName)
        copyUriToFile(uri, target, ByteArray(COPY_BUFFER_SIZE))
        return mapOf(
            "path" to target.absolutePath,
            "cleanupRoot" to targetDir.absolutePath
        )
    }

    private fun copyComicDirectory(treeUri: Uri, destDir: String): Map<String, String> {
        val targetDir = File(destDir)
        targetDir.mkdirs()
        val rootDocumentId = DocumentsContract.getTreeDocumentId(treeUri)
        val fallbackName = rootDocumentId
            .substringAfterLast(':')
            .substringAfterLast('/')
            .ifBlank { "comic" }
        val rootName = sanitizeFileName(
            queryDisplayName(DocumentsContract.buildDocumentUriUsingTree(treeUri, rootDocumentId))
                ?: fallbackName
        )
        val target = File(targetDir, rootName)
        target.mkdirs()
        // 整个目录共用一块缓冲区，避免每个文件都分配 1 MiB。
        copyDocumentChildren(treeUri, rootDocumentId, target, ByteArray(COPY_BUFFER_SIZE))
        return mapOf(
            "path" to target.absolutePath,
            "cleanupRoot" to targetDir.absolutePath
        )
    }

    private fun copyDocumentChildren(
        treeUri: Uri,
        parentDocumentId: String,
        targetDir: File,
        buffer: ByteArray,
    ) {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocumentId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE
        )
        contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val documentId = cursor.getString(0)
                val name = sanitizeFileName(cursor.getString(1) ?: "unnamed")
                val mimeType = cursor.getString(2)
                val childUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
                if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                    val childDir = File(targetDir, name)
                    childDir.mkdirs()
                    copyDocumentChildren(treeUri, documentId, childDir, buffer)
                } else {
                    copyUriToFile(childUri, File(targetDir, name), buffer)
                }
            }
        } ?: throw IllegalStateException("Cannot list document children for $childrenUri")
    }

    private fun queryDisplayName(uri: Uri): String? {
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                return cursor.getString(0)
            }
        }
        return uri.lastPathSegment
    }

    private fun sanitizeFileName(raw: String): String {
        val cleaned = raw
            .replace(INVALID_FILE_NAME_CHARS, "_")
            .trim()
            .trimEnd('.')
        return if (cleaned.isEmpty() || cleaned == "." || cleaned == "..") "unnamed" else cleaned
    }

    private fun copyUriToFile(uri: Uri, destFile: File, buffer: ByteArray) {
        destFile.parentFile?.mkdirs()
        contentResolver.openInputStream(uri)?.use { input ->
            destFile.outputStream().use { output ->
                var bytesRead: Int
                var totalCopied = 0L
                var nextProgressLog = COPY_PROGRESS_LOG_STEP
                while (input.read(buffer).also { bytesRead = it } > 0) {
                    output.write(buffer, 0, bytesRead)
                    totalCopied += bytesRead
                    if (totalCopied >= nextProgressLog) {
                        Log.i("FilePicker", "已拷贝 ${totalCopied / 1024 / 1024} MB")
                        nextProgressLog += COPY_PROGRESS_LOG_STEP
                    }
                }
            }
        } ?: throw IllegalStateException("Cannot open input stream for $uri")
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_PICK_BACKUP_ZIP) {
            Log.i("FilePicker", "onActivityResult: resultCode=$resultCode, data=$data")
            val result = pendingFilePickerResult
            val destPath = pendingFilePickerDestPath
            pendingFilePickerResult = null
            pendingFilePickerDestPath = null

            if (resultCode == Activity.RESULT_OK && data?.data != null && destPath != null) {
                val uri = data.data!!
                Thread {
                    try {
                        copyUriToFile(uri, File(destPath), ByteArray(COPY_BUFFER_SIZE))
                        Log.i("FilePicker", "拷贝完成：$destPath")
                        runOnUiThread { result?.success(destPath) }
                    } catch (e: Exception) {
                        Log.e("FilePicker", "拷贝失败", e)
                        runOnUiThread { result?.error("COPY_ERROR", e.message, e.stackTraceToString()) }
                    }
                }.start()
            } else {
                Log.i("FilePicker", "用户取消或失败")
                result?.success(null)
            }
            return
        }

        if (requestCode == REQUEST_CODE_PICK_COMIC_ARCHIVE ||
            requestCode == REQUEST_CODE_PICK_COMIC_DIRECTORY
        ) {
            Log.i("FilePicker", "onActivityResult comic: requestCode=$requestCode, resultCode=$resultCode")
            val result = pendingComicPickerResult
            val destDir = pendingComicPickerDestDir
            pendingComicPickerResult = null
            pendingComicPickerDestDir = null

            if (resultCode == Activity.RESULT_OK && data?.data != null && destDir != null) {
                val uri = data.data!!
                Thread {
                    try {
                        val payload = if (requestCode == REQUEST_CODE_PICK_COMIC_ARCHIVE) {
                            copyComicArchive(uri, destDir)
                        } else {
                            copyComicDirectory(uri, destDir)
                        }
                        Log.i("FilePicker", "外部漫画拷贝完成：$payload")
                        runOnUiThread { result?.success(payload) }
                    } catch (e: Exception) {
                        Log.e("FilePicker", "外部漫画拷贝失败", e)
                        runOnUiThread { result?.error("COPY_ERROR", e.message, e.stackTraceToString()) }
                    }
                }.start()
            } else {
                Log.i("FilePicker", "用户取消外部漫画选择")
                result?.success(null)
            }
        }
    }

    private fun saveForceEnableImpeller(enable: Boolean) {
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_FORCE_ENABLE_IMPELLER, enable)
            .apply()
    }

    private fun isForceEnableImpeller(): Boolean {
        return getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_FORCE_ENABLE_IMPELLER, false)
    }

    private fun getMemoryInfo(): Map<String, Long> {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memoryInfo = ActivityManager.MemoryInfo()
        activityManager.getMemoryInfo(memoryInfo)

        // 获取应用的内存使用情况
        val memoryClass = activityManager.memoryClass
        val largeMemoryClass = activityManager.largeMemoryClass
        
        // 获取当前进程的内存使用
        val runtime = Runtime.getRuntime()
        val nativeHeapSize = Debug.getNativeHeapSize()
        val nativeHeapAllocatedSize = Debug.getNativeHeapAllocatedSize()
        val nativeHeapFreeSize = Debug.getNativeHeapFreeSize()

        return mapOf(
            "totalMemory" to memoryInfo.totalMem,
            "availableMemory" to memoryInfo.availMem,
            "threshold" to memoryInfo.threshold,
            "lowMemory" to if (memoryInfo.lowMemory) 1L else 0L,
            "memoryClass" to memoryClass.toLong() * 1024 * 1024, // Convert MB to bytes
            "largeMemoryClass" to largeMemoryClass.toLong() * 1024 * 1024,
            "maxMemory" to runtime.maxMemory(),
            "totalMemoryRuntime" to runtime.totalMemory(),
            "freeMemoryRuntime" to runtime.freeMemory(),
            "nativeHeapSize" to nativeHeapSize,
            "nativeHeapAllocatedSize" to nativeHeapAllocatedSize,
            "nativeHeapFreeSize" to nativeHeapFreeSize
        )
    }

    private fun getDartMemoryInfo(): Map<String, Long> {
        val runtime = Runtime.getRuntime()
        
        // 获取 Runtime 内存信息
        val maxMemory = runtime.maxMemory()
        val totalMemory = runtime.totalMemory()
        val freeMemory = runtime.freeMemory()
        val usedMemory = totalMemory - freeMemory
        
        // 进程级 PSS：优先读 /proc/self/smaps_rollup（内核聚合，单文件），
        // Android 8.x 等老内核没有该文件时回退到 ActivityManager。
        val (processPss, processPrivateDirty, processSharedDirty) =
            readSelfSmapsRollup() ?: readProcessMemoryStatsViaActivityManager()
        
        // 获取 Native 堆信息
        val nativeHeapSize = Debug.getNativeHeapSize()
        val nativeHeapAllocated = Debug.getNativeHeapAllocatedSize()
        val nativeHeapFree = Debug.getNativeHeapFreeSize()
        
        return mapOf(
            "dartHeapUsed" to usedMemory,
            "dartHeapCapacity" to maxMemory,
            "dartHeapCommitted" to totalMemory,
            "externalMemory" to nativeHeapAllocated,
            "maxMemory" to maxMemory,
            "totalMemory" to totalMemory,
            "freeMemory" to freeMemory,
            "usedMemory" to usedMemory,
            "nativeHeapSize" to nativeHeapSize,
            "nativeHeapAllocated" to nativeHeapAllocated,
            "nativeHeapFree" to nativeHeapFree,
            "processPss" to processPss, // 字节
            "processPrivateDirty" to processPrivateDirty,
            "processSharedDirty" to processSharedDirty
        )
    }

    /// 读取 /proc/self/smaps_rollup 的进程内存统计（pss, privateDirty, sharedDirty，单位字节）。
    ///
    /// 相比 ActivityManager.getProcessMemoryInfo，省掉一次 binder 进 system_server
    /// 的全量 smaps 解析（本进程有 Flutter / Impeller / Rust 等大量映射，开销明显）。
    /// 内核 4.14（Android 9）起才有这个文件，更老的系统返回 null 交给调用方回退。
    private fun readSelfSmapsRollup(): Triple<Long, Long, Long>? {
        val file = File("/proc/self/smaps_rollup")
        if (!file.exists()) {
            return null
        }
        var pss = -1L
        var privateDirty = -1L
        var sharedDirty = -1L
        try {
            file.useLines { lines ->
                for (line in lines) {
                    when {
                        line.startsWith("Pss:") ->
                            pss = smapsKilobytes(line) ?: pss
                        line.startsWith("Private_Dirty:") ->
                            privateDirty = smapsKilobytes(line) ?: privateDirty
                        line.startsWith("Shared_Dirty:") ->
                            sharedDirty = smapsKilobytes(line) ?: sharedDirty
                    }
                }
            }
        } catch (_: Exception) {
            return null
        }
        if (pss < 0 || privateDirty < 0 || sharedDirty < 0) {
            return null
        }
        return Triple(pss, privateDirty, sharedDirty)
    }

    /// 解析 smaps 行（如 "Pss:  1234 kB"）里的 kB 数值并转成字节。
    private fun smapsKilobytes(line: String): Long? =
        line.substringAfter(':', "")
            .trim()
            .substringBefore(' ')
            .toLongOrNull()
            ?.times(1024)

    /// 老内核的回退路径：ActivityManager 会把本进程 smaps 全量解析一遍，较慢。
    private fun readProcessMemoryStatsViaActivityManager(): Triple<Long, Long, Long> {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val pmi = activityManager
            .getProcessMemoryInfo(intArrayOf(android.os.Process.myPid()))
            .firstOrNull()
        return Triple(
            pmi?.totalPss?.toLong()?.times(1024) ?: 0L,
            pmi?.totalPrivateDirty?.toLong()?.times(1024) ?: 0L,
            pmi?.totalSharedDirty?.toLong()?.times(1024) ?: 0L
        )
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (volumeKeyInterceptionEnabled) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeEventSink?.success("volume_down")
                    return true // 拦截事件
                }
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeEventSink?.success("volume_up")
                    return true // 拦截事件
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    @Suppress("DEPRECATION")
    private fun setInstantSystemUiVisibility(immersive: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val controller = window.decorView.windowInsetsController ?: run {
                fallbackSystemUiVisibility(immersive)
                return
            }
            if (immersive) {
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
            } else {
                controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_DEFAULT
                controller.show(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
            }
            return
        }
        fallbackSystemUiVisibility(immersive)
    }

    /// 只隐藏底部导航栏，保留顶部状态栏（阅读器“显示状态栏”开关用）。
    private fun setNavigationBarOnlyVisibility() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val controller = window.decorView.windowInsetsController ?: run {
                fallbackNavigationBarOnlyVisibility()
                return
            }
            controller.systemBarsBehavior =
                WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.show(WindowInsets.Type.statusBars())
            controller.hide(WindowInsets.Type.navigationBars())
            return
        }
        fallbackNavigationBarOnlyVisibility()
    }

    @Suppress("DEPRECATION")
    private fun fallbackSystemUiVisibility(immersive: Boolean) {
        var flags = (
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        )
        if (immersive) {
            flags = flags or (
                View.SYSTEM_UI_FLAG_FULLSCREEN
                or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_IMMERSIVE
            )
        }
        window.decorView.systemUiVisibility = flags
    }

    @Suppress("DEPRECATION")
    private fun fallbackNavigationBarOnlyVisibility() {
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_IMMERSIVE
        )
    }
}
