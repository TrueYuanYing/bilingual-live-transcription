package com.classmate.classmate

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.io.FileOutputStream

/** Copies large model assets on a background queue without transferring them
 * through the Flutter UI isolate. Only bundled ASR files can be copied. */
class AsrModelAssets(context: Context, messenger: BinaryMessenger) {
    init {
        val app = context.applicationContext
        MethodChannel(messenger, "com.iko.study/asr_models",
            StandardMethodCodec.INSTANCE, messenger.makeBackgroundTaskQueue())
            .setMethodCallHandler { call, result ->
                if (call.method != "copyModel") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                var temporary: File? = null
                try {
                    val language = call.argument<String>("language")
                    val name = call.argument<String>("file")
                    require(language in setOf("zh", "en", "auto")) { "Invalid model language" }
                    val streamingFiles = setOf("tokens.txt", "encoder.int8.onnx", "decoder.onnx", "joiner.onnx")
                    val offlineFiles = setOf("model.int8.onnx", "offline-tokens.txt")
                    require(name in streamingFiles || (language == "auto" && name in offlineFiles)) { "Invalid model file" }
                    val expected = requireNotNull(call.argument<Number>("length")).toLong()
                    require(expected in 1..512L * 1024 * 1024) { "Invalid model length" }
                    val root = File(app.getDir("flutter", Context.MODE_PRIVATE), "sherpa_models").canonicalFile
                    val target = File(requireNotNull(call.argument<String>("target"))).canonicalFile
                    require(target.path.startsWith(root.path + File.separator) &&
                        target.name == name && target.parentFile?.name == language) { "Invalid model target" }
                    val parent = requireNotNull(target.parentFile)
                    check(parent.isDirectory || parent.mkdirs()) { "Cannot create model directory" }
                    val temp = File(target.path + ".partial")
                    temporary = temp
                    val asset = FlutterInjector.instance().flutterLoader()
                        .getLookupKeyForAsset("assets/sherpa/$language/$name")
                    app.assets.open(asset).use { input ->
                        FileOutputStream(temp).use { output ->
                            val buffer = ByteArray(64 * 1024)
                            var total = 0L
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                total += count
                                check(total <= expected) { "Model length exceeds manifest" }
                                output.write(buffer, 0, count)
                            }
                            check(total == expected) { "Incomplete model asset" }
                            output.fd.sync()
                        }
                    }
                    check(temp.renameTo(target)) { "Cannot install model" }
                    result.success(null)
                } catch (error: Exception) {
                    temporary?.delete()
                    result.error("MODEL_COPY", error.message, null)
                }
            }
    }
}
