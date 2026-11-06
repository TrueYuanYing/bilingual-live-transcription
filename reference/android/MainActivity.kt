package com.classmate.classmate

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.Context
import android.net.Uri
import android.location.LocationManager
import android.os.Build
import android.provider.Settings
import android.content.IntentFilter
import android.os.Bundle
import android.webkit.WebView
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.ContextCompat

class MainActivity : FlutterActivity() {
    private var studyResources: StudyResources? = null
    private var academicImport: AcademicImportBridge? = null
    private var classroomRecording: ClassroomRecordingBridge? = null
    private var backupBridge: BackupBridge? = null
    private var notesBridge: NotesBridge? = null
    private var resourcePacksBridge: ResourcePacksBridge? = null
    private var appUpdateBridge: AppUpdateBridge? = null
    private var storageBridge: StorageBridge? = null
    private fun captureOrTransferBusy(): Boolean = app.iko.notes.NotesHost.state["running"] == true ||
        app.iko.notes.NotesHost.recording() || notesBridge?.busy == true || backupBridge?.busy == true

    override fun onResume() { super.onResume(); notesBridge?.workspace?.onResume() }
    override fun onPause() { notesBridge?.workspace?.onPause(); super.onPause() }
    override fun onStop() { notesBridge?.workspace?.onStop(); super.onStop() }
    override fun onSaveInstanceState(outState: Bundle) { notesBridge?.workspace?.saveState(outState); super.onSaveInstanceState(outState) }
    override fun onConfigurationChanged(config: android.content.res.Configuration) {
        super.onConfigurationChanged(config); notesBridge?.workspace?.onConfigurationChanged(config)
    }
    override fun onRequestPermissionsResult(request: Int, permissions: Array<out String>, grants: IntArray) {
        if (notesBridge?.workspace?.onRequestPermissionsResult(request, permissions, grants) == true) return
        super.onRequestPermissionsResult(request, permissions, grants)
    }
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        if (notesBridge?.workspace?.isVisible == true && notesBridge?.workspace?.preDispatchKeyEvent(event) == true) return true
        return super.dispatchKeyEvent(event)
    }
    @Deprecated("Flutter embedding compatibility")
    override fun onBackPressed() {
        if (notesBridge?.workspace?.isVisible == true && notesBridge?.workspace?.handleBack() == true) return
        super.onBackPressed()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        BackupBridge.recoverBeforeLaunch(this)
        IkoAppearance.prepare(this)
        if ((applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            WebView.setWebContentsDebuggingEnabled(true)
        }
        super.onCreate(savedInstanceState)
        notesBridge?.workspace?.restoreState(savedInstanceState)
        notesBridge?.acceptIncoming(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        notesBridge?.acceptIncoming(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (backupBridge?.onResult(requestCode, resultCode, data) == true) return
        if (notesBridge?.onResult(requestCode, resultCode, data) == true) return
        if (resourcePacksBridge?.onResult(requestCode, resultCode, data) == true) return
        if (classroomRecording?.onResult(requestCode, resultCode, data) == true) return
        if (academicImport?.onResult(requestCode, resultCode, data) == true) return
        if (studyResources?.onResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    private companion object {
        const val CHANNEL = "com.classmate.classmate/icon"
        const val SYSTEM_CHANNEL = "com.classmate.classmate/system_alert"
        const val SPEECH_CHANNEL = "com.classmate.classmate/system_speech"
        const val SPEECH_EVENTS = "com.classmate.classmate/system_speech_events"
        const val ALERT_CHANNEL_ID = "iko_alerts"
        const val ALERT_PERMISSION_REQUEST = 9012
    }

    private val speechHandler = Handler(Looper.getMainLooper())
    private fun startForegroundCapture(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED) {
            result.error("microphone_permission", "麦克风权限未授予", null)
            return
        }
        if (!lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED) && !app.iko.notes.NotesHost.isVisible()) {
            result.error("microphone_background", "请返回 IKO 后开始听写", null)
            return
        }
        if (RecordingForegroundService.onStartResult != null) {
            result.error("capture_busy", "听写正在启动", null)
            return
        }
        val timeout = Runnable {
            val pending = RecordingForegroundService.onStartResult
            RecordingForegroundService.onStartResult = null
            pending?.invoke(IllegalStateException("听写服务启动超时"))
            stopService(Intent(this, RecordingForegroundService::class.java))
        }
        RecordingForegroundService.onStartResult = { error ->
            speechHandler.removeCallbacks(timeout)
            if (error == null) result.success(null)
            else result.error("capture_unavailable", error.message, null)
        }
        speechHandler.postDelayed(timeout, 8000)
        try {
            createAlertChannel()
            ContextCompat.startForegroundService(this,
                Intent(this, RecordingForegroundService::class.java))
        } catch (error: Exception) {
            val pending = RecordingForegroundService.onStartResult
            RecordingForegroundService.onStartResult = null
            pending?.invoke(error)
        }
    }
    private var speechRecognizer: SpeechRecognizer? = null
    private var speechEvents: EventChannel.EventSink? = null
    private var speechActive = false
    private var speechListening = false
    private var speechLanguage = "zh"
    private var speechRestart: Runnable? = null

    override fun onDestroy() {
        appUpdateBridge?.dispose()
        storageBridge?.dispose()
        resourcePacksBridge?.dispose()
        notesBridge?.dispose()
        backupBridge?.dispose()
        classroomRecording?.dispose()
        cancelSystemSpeech()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        notesBridge = NotesBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        resourcePacksBridge = ResourcePacksBridge(this, flutterEngine.dartExecutor.binaryMessenger, ::captureOrTransferBusy)
        storageBridge = StorageBridge(this, flutterEngine.dartExecutor.binaryMessenger) { captureOrTransferBusy() || resourcePacksBridge?.busy == true }
        appUpdateBridge = AppUpdateBridge(this, flutterEngine.dartExecutor.binaryMessenger,
            { captureOrTransferBusy() || resourcePacksBridge?.busy == true },
            { callback -> notesBridge?.workspace?.flush(callback) ?: callback(null) })
        backupBridge = BackupBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        classroomRecording = ClassroomRecordingBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        IkoAppearance(this, flutterEngine.dartExecutor.binaryMessenger)
        studyResources = StudyResources(this, flutterEngine.dartExecutor.binaryMessenger)
        academicImport = AcademicImportBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        AsrModelAssets(this, flutterEngine.dartExecutor.binaryMessenger)
        WebQuestionBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.iko.study/app_info")
            .setMethodCallHandler { call, result ->
                if (call.method == "getVersionName") {
                    @Suppress("DEPRECATION")
                    val installed = packageManager.getPackageInfo(packageName, 0)
                    result.success(installed.versionName)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "setIconMode") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val mode = call.argument<String>("mode") ?: "light"
                setLauncherIcon(mode)
                result.success(null)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAlertStatus" -> {
                        createAlertChannel()
                        val manager = getSystemService(NotificationManager::class.java)
                        val channel = if (Build.VERSION.SDK_INT >= 26) manager.getNotificationChannel(ALERT_CHANNEL_ID) else null
                        result.success(mapOf("enabled" to manager.areNotificationsEnabled(),
                            "importance" to (channel?.importance ?: 4),
                            "sound" to (channel?.sound != null),
                            "dnd" to (manager.currentInterruptionFilter != NotificationManager.INTERRUPTION_FILTER_ALL)))
                    }
                    "openAlertSettings" -> {
                        createAlertChannel()
                        val settingsIntent = if (Build.VERSION.SDK_INT >= 26) Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            .putExtra(Settings.EXTRA_CHANNEL_ID, ALERT_CHANNEL_ID)
                        else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                        try { startActivity(settingsIntent) }
                        catch (_: android.content.ActivityNotFoundException) {
                            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                        }
                        result.success(null)
                    }
                    "testAlert" -> {
                        createAlertChannel()
                        speechHandler.postDelayed({ showAlert("IKO · 横幅测试", "这是课堂提醒测试。点击可返回 IKO。", true) }, 5000)
                        result.success(null)
                    }
                    "requestNotificationPermission" -> {
                        requestNotificationPermission()
                        result.success(null)
                    }
                    "startForegroundCapture" -> {
                        startForegroundCapture(result)
                    }
                    "getBatteryLevel" -> {
                        result.success(readBatteryLevel())
                    }
                    "isAirplaneModeOn" -> {
                        result.success(readAirplaneMode())
                    }
                    "getLocation" -> {
                        result.success(readLastLocation())
                    }
                    "openAirplaneSettings" -> {
                        startActivity(Intent(Settings.ACTION_AIRPLANE_MODE_SETTINGS))
                        result.success(null)
                    }
                    "startFocusAudio" -> {
                        val intent = Intent(this, FocusAudioService::class.java)
                            .putExtra("engineVolume", call.argument<Double>("engineVolume") ?: 0.28)
                            .putExtra("whiteNoiseVolume", call.argument<Double>("whiteNoiseVolume") ?: 0.14)
                            .putExtra("rainVolume", call.argument<Double>("rainVolume") ?: 0.0)
                        ContextCompat.startForegroundService(this, intent)
                        result.success(null)
                    }
                    "setFocusAudioVolumes" -> {
                        FocusAudioService.setCurrentVolumes(
                            (call.argument<Double>("engineVolume") ?: 0.28).toFloat(),
                            (call.argument<Double>("whiteNoiseVolume") ?: 0.14).toFloat(),
                            (call.argument<Double>("rainVolume") ?: 0.0).toFloat(),
                        )
                        result.success(null)
                    }
                    "playFocusSfx" -> {
                        FocusAudioService.playSfx(
                            call.argument<String>("name") ?: "",
                            (call.argument<Double>("volume") ?: 0.22).toFloat(),
                        )
                        result.success(null)
                    }
                    "setFocusAudioDucking" -> {
                        FocusAudioService.setDucking(
                            (call.argument<Double>("factor") ?: 1.0).toFloat(),
                        )
                        result.success(null)
                    }
                    "stopFocusAudio" -> {
                        stopService(Intent(this, FocusAudioService::class.java))
                        result.success(null)
                    }
                    "stopForegroundCapture" -> {
                        stopService(Intent(this, RecordingForegroundService::class.java))
                        result.success(null)
                    }
                    "showAlert" -> {
                        createAlertChannel()
                        showAlert(
                            call.argument<String>("title") ?: "IKO · 课堂预警",
                            call.argument<String>("body") ?: "请查看 IKO",
                            call.argument<Boolean>("confirmed") ?: false,
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SPEECH_EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    speechEvents = events
                }

                override fun onCancel(arguments: Any?) {
                    speechEvents = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SPEECH_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> result.success(
                        SpeechRecognizer.isRecognitionAvailable(this),
                    )
                    "start" -> startSystemSpeech(
                        call.argument<String>("language") ?: "zh",
                        result,
                    )
                    "finish" -> finishSystemSpeech(result)
                    "cancel" -> {
                        cancelSystemSpeech()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun startSystemSpeech(language: String, result: MethodChannel.Result) {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            result.error("UNAVAILABLE", "系统没有可用的语音识别服务", null)
            return
        }
        cancelSystemSpeech()
        speechLanguage = if (language == "en") "en" else "zh"
        try {
            speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this).apply {
                setRecognitionListener(SystemSpeechListener())
            }
            speechActive = true
            startSystemSpeechListening()
            result.success(null)
        } catch (error: Exception) {
            cancelSystemSpeech()
            result.error("START_FAILED", error.message, null)
        }
    }

    private fun startSystemSpeechListening() {
        val recognizer = speechRecognizer ?: return
        if (!speechActive || speechListening) return
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE,
                if (speechLanguage == "en") "en-US" else "zh-CN",
            )
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            // 系统默认服务可按设备能力选择网络或本地模型，以优先保证课堂准确率。
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false)
        }
        try {
            speechListening = true
            recognizer.startListening(intent)
        } catch (_: Exception) {
            speechListening = false
            scheduleSystemSpeechRestart()
        }
    }

    private fun scheduleSystemSpeechRestart() {
        speechRestart?.let(speechHandler::removeCallbacks)
        val restart = Runnable {
            speechRestart = null
            startSystemSpeechListening()
        }
        speechRestart = restart
        speechHandler.postDelayed(restart, 140L)
    }

    private fun finishSystemSpeech(result: MethodChannel.Result) {
        speechActive = false
        speechRestart?.let(speechHandler::removeCallbacks)
        speechRestart = null
        try {
            speechRecognizer?.stopListening()
        } catch (_: Exception) {
            destroySystemSpeech()
        }
        speechHandler.postDelayed({ destroySystemSpeech() }, 900L)
        result.success(null)
    }

    private fun cancelSystemSpeech() {
        speechActive = false
        speechRestart?.let(speechHandler::removeCallbacks)
        speechRestart = null
        try {
            speechRecognizer?.cancel()
        } catch (_: Exception) {
            // recognizer 释放继续执行
        }
        destroySystemSpeech()
    }

    private fun destroySystemSpeech() {
        speechListening = false
        speechRecognizer?.destroy()
        speechRecognizer = null
    }

    private fun emitSystemSpeech(text: String, isFinal: Boolean) {
        if (text.isBlank()) return
        speechEvents?.success(
            mapOf(
                "text" to text,
                "isFinal" to isFinal,
                "language" to if (speechLanguage == "en") "en" else "zh",
            ),
        )
    }

    private inner class SystemSpeechListener : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) = Unit
        override fun onBeginningOfSpeech() = Unit
        override fun onRmsChanged(rmsdB: Float) = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit
        override fun onEndOfSpeech() = Unit
        override fun onPartialResults(results: Bundle?) {
            val text = results
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?: return
            emitSystemSpeech(text, false)
        }

        override fun onResults(results: Bundle?) {
            speechListening = false
            val text = results
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?: ""
            emitSystemSpeech(text, true)
            if (speechActive) scheduleSystemSpeechRestart()
        }

        override fun onError(error: Int) {
            speechListening = false
            if (speechActive) scheduleSystemSpeechRestart()
        }

        override fun onEvent(eventType: Int, params: Bundle?) = Unit
    }

    private fun readBatteryLevel(): Int? {
        val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?: return null
        val level = intent.getIntExtra("level", -1)
        val scale = intent.getIntExtra("scale", -1)
        return if (level >= 0 && scale > 0) level * 100 / scale else null
    }

    private fun readAirplaneMode(): Boolean = try {
        Settings.Global.getInt(
            contentResolver,
            Settings.Global.AIRPLANE_MODE_ON,
            0,
        ) == 1
    } catch (_: Settings.SettingNotFoundException) {
        false
    }

    private fun readLastLocation(): Map<String, Double>? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) !=
            PackageManager.PERMISSION_GRANTED &&
            checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) !=
            PackageManager.PERMISSION_GRANTED
        ) return null
        return try {
            val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            manager.getProviders(true)
                .mapNotNull { provider -> manager.getLastKnownLocation(provider) }
                .minByOrNull { it.accuracy }
                ?.let { mapOf("latitude" to it.latitude, "longitude" to it.longitude) }
        } catch (_: SecurityException) {
            null
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                ALERT_PERMISSION_REQUEST,
            )
        }
    }

    private fun createAlertChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                ALERT_CHANNEL_ID,
                "IKO 点名与提问预警",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "疑似点名/提问和命中本人时提醒"
                enableVibration(true)
                setShowBadge(true)
            },
        )
    }

    private fun showAlert(title: String, body: String, confirmed: Boolean) {
        createAlertChannel()
        val manager = getSystemService(NotificationManager::class.java)
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val contentIntent = PendingIntent.getActivity(this, 9013,
            launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, ALERT_CHANNEL_ID)
        } else {
            Notification.Builder(this)
                .setPriority(Notification.PRIORITY_MAX)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(contentIntent)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setDefaults(Notification.DEFAULT_ALL)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOnlyAlertOnce(false)
            .setColor(if (confirmed) 0xFFD92332.toInt() else 0xFFFFC400.toInt())
            .build()
        manager.notify(if (confirmed) 9014 else 9015, notification)
    }

    private fun setLauncherIcon(mode: String) {
        val manager = packageManager
        val aliases = mapOf(
            "light" to ".MainActivityLight",
            "dark" to ".MainActivityDark",
            "ocean" to ".MainActivityOcean",
            "forest" to ".MainActivityForest",
            "plum" to ".MainActivityPlum",
        )
        val selected = aliases[mode] ?: aliases.getValue("light")
        // First expose the new launcher activity, then hide the old one.
        setAliasState(manager, selected, true)
        aliases.values.filter { it != selected }.forEach {
            setAliasState(manager, it, false)
        }
    }

    private fun setAliasState(
        manager: PackageManager,
        className: String,
        enabled: Boolean,
    ) {
        val activityPackage = MainActivity::class.java.name.substringBeforeLast('.')
        val component = ComponentName(this, "$activityPackage$className")
        val desired = if (enabled) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
        if (manager.getComponentEnabledSetting(component) == desired) return
        manager.setComponentEnabledSetting(
            component,
            desired,
            PackageManager.DONT_KILL_APP,
        )
    }
}
