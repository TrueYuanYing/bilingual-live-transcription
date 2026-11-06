package com.classmate.classmate

import android.app.Activity
import android.content.Intent
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaPlayer
import android.os.Build
import android.util.AtomicFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import org.json.JSONObject
import java.io.File

/** Encodes supplied PCM only. Never creates AudioRecord/MediaRecorder or requests audio focus. */
class ClassroomRecordingBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val directory = File(activity.filesDir, "classroom_recordings").apply { mkdirs() }
    private val lock = Any()
    private val channel = MethodChannel(messenger, "com.iko.study/classroom_recording",
        StandardMethodCodec.INSTANCE, messenger.makeBackgroundTaskQueue())
    private var run: Run? = null
    private var closed = false
    // Player and document picker belong to the Activity main thread; encoder belongs to the task queue.
    private var player: MediaPlayer? = null
    private var playerClip: String? = null
    private var playerReady = false
    private var pendingExport: MethodChannel.Result? = null
    private var exportFile: File? = null

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> synchronized(lock) {
                        check(!closed) { "录音服务已关闭" }
                        finishRun()
                        val id = safeId(call.argument<String>("id"))
                        val session = call.argument<String>("sessionJson") ?: error("课堂信息缺失")
                        require(session.length <= 1024 * 1024) { "课堂信息过大" }
                        safeId(JSONObject(session).getString("id"))
                        val bitrate = call.argument<Int>("bitrate")?.takeIf { it in listOf(8000,12000,16000) } ?: 12000
                        val owner=call.argument<String>("noteOwner")
                        val created = Run(id, session, bitrate, owner)
                        run = created
                        result.success(mapOf("format" to created.encoder.formatLabel))
                    }
                    "append" -> synchronized(lock) {
                        val current = requireRun(call.argument<String>("id"))
                        val pcm = call.argument<ByteArray>("pcm") ?: error("录音数据缺失")
                        require(pcm.size <= 32000) { "录音队列过大" }
                        try {
                            current.append(pcm)
                            result.success(current.stats())
                        } catch (e: Exception) {
                            finishRun()
                            throw e
                        }
                    }
                    "stop" -> synchronized(lock) {
                        // An old session may finish after a new screen has requested capture.
                        if (run?.id == call.argument<String>("id")) finishRun()
                        result.success(null)
                    }
                    "list" -> synchronized(lock) { result.success(listClips()) }
                    "delete", "deleteClips" -> synchronized(lock) {
                        val clips = if(call.method == "delete") {
                            val sessionId = safeId(call.argument<String>("sessionId"))
                            check(run?.sessionId != sessionId) { "请先停止这节课的录音" }
                            listClips().filter { it["sessionId"] == sessionId }
                        } else {
                            val ids=(call.argument<List<String>>("clipIds") ?: emptyList()).map { safeId(it) }.toSet()
                            check(run == null) { "请先停止录音" }
                            listClips().filter { it["id"] in ids }
                        }
                        for (clip in clips) {
                            val id = clip["id"] as String
                            val meta = readMeta(id)
                            val audio = audioFile(meta)
                            check(!audio.exists() || audio.delete()) { "无法删除录音" }
                            AtomicFile(metaFile(id)).delete()
                        }
                        activity.runOnUiThread { stopPlayer() }
                        result.success(null)
                    }
                    "play" -> {
                        val id = safeId(call.argument<String>("clipId"))
                        val file = audioFile(readMeta(id))
                        activity.runOnUiThread {
                            try {
                                if (playerClip == id && playerReady) {
                                    player?.start()
                                } else {
                                    stopPlayer()
                                    val media = MediaPlayer()
                                    player = media
                                    playerClip = id
                                    media.setDataSource(file.path)
                                    media.setOnPreparedListener {
                                        if (player === it) { playerReady = true; it.start() }
                                    }
                                    media.setOnErrorListener { failed, _, _ ->
                                        if (player === failed) stopPlayer()
                                        true
                                    }
                                    media.prepareAsync()
                                }
                                result.success(null)
                            } catch (e: Exception) {
                                stopPlayer(); result.error("PLAYBACK", "无法回放这段录音", null)
                            }
                        }
                    }
                    "pause", "stopPlayback", "seek", "player" -> activity.runOnUiThread {
                        try {
                            when (call.method) {
                                "pause" -> if (playerReady && player?.isPlaying == true) player?.pause()
                                "stopPlayback" -> stopPlayer()
                                "seek" -> if (playerReady) player?.seekTo(
                                    (call.argument<Int>("positionMs") ?: 0).coerceIn(0, player!!.duration))
                            }
                            result.success(if (call.method == "player") mapOf(
                                "clipId" to playerClip, "ready" to playerReady,
                                "playing" to (playerReady && player?.isPlaying == true),
                                "positionMs" to if (playerReady) player?.currentPosition else 0,
                                "durationMs" to if (playerReady) player?.duration else 0
                            ) else null)
                        } catch (e: Exception) {
                            stopPlayer(); result.error("PLAYBACK", "回放暂不可用", null)
                        }
                    }
                    "share" -> {
                        val ids=call.argument<List<String>>("clipIds") ?: error("请选择录音")
                        require(ids.isNotEmpty() && ids.size<=200) { "一次最多分享200段" }
                        val files=synchronized(lock) {
                            check(run==null) { "请先结束录音，再分享文件" }
                            val target=File(activity.cacheDir,"share").apply { mkdirs() }
                            ids.mapIndexed { index, raw ->
                                val id=safeId(raw);val meta=readMeta(id)
                                check(meta.optBoolean("complete")) { "这段录音尚未保存完成" }
                                val source=audioFile(meta)
                                File(target,"IKO-${meta.getLong("startedAt")}-${index+1}.${source.extension}").also { source.copyTo(it,true) }
                            }
                        }
                        val asFile=call.argument<Boolean>("asFile") != false
                        val mime=if(asFile) "application/octet-stream" else if(files.all { it.extension=="webm" }) "audio/webm" else if(files.all { it.extension=="m4a" }) "audio/mp4" else "application/octet-stream"
                        val target=call.argument<String>("target")
                        activity.runOnUiThread {
                            try { app.iko.notes.MainlandShare.shareFiles(activity,files,mime,target);result.success(null) }
                            catch(e:Exception){result.error("SHARE","无法打开分享目标，请尝试系统更多或原文件方式",null)}
                        }
                    }
                    "export" -> {
                        val id = safeId(call.argument<String>("clipId"))
                        val meta = readMeta(id)
                        val file = audioFile(meta)
                        activity.runOnUiThread {
                            if (pendingExport != null) result.error("BUSY", "请先完成当前导出", null)
                            else try {
                                pendingExport = result; exportFile = file
                                activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = if (file.extension == "webm") "audio/webm" else "audio/mp4"
                                    putExtra(Intent.EXTRA_TITLE, "IKO-课堂录音-${meta.getLong("startedAt")}.${file.extension}")
                                }, EXPORT_REQUEST)
                            } catch (e: Exception) {
                                pendingExport = null; exportFile = null
                                result.error("EXPORT", "无法打开保存位置", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("RECORDING", e.message ?: "录音暂不可用", null)
            }
        }
    }

    private fun requireRun(id: String?): Run {
        val current = run ?: error("录音已结束")
        check(current.id == id) { "录音会话已切换" }
        return current
    }

    private fun safeId(id: String?): String {
        require(id != null && Regex("[a-zA-Z0-9_-]{1,96}").matches(id)) { "录音标识无效" }
        return id
    }
    private fun metaFile(id: String) = File(directory, "${safeId(id)}.json")
    private fun readMeta(id: String) = JSONObject(AtomicFile(metaFile(id)).openRead().bufferedReader().use { it.readText() })
    private fun audioFile(meta: JSONObject): File {
        val name = meta.getString("fileName")
        require(Regex("[a-zA-Z0-9_-]+\\.(webm|m4a)").matches(name)) { "录音路径无效" }
        return File(directory, name)
    }

    private fun listClips(): List<Map<String, Any>> = directory.listFiles()
        ?.filter { it.extension == "json" }?.mapNotNull { file ->
            try {
                val meta = readMeta(file.nameWithoutExtension)
                val audio = audioFile(meta)
                if (!audio.isFile || audio.length() == 0L) null else mapOf(
                    "id" to meta.getString("id"), "sessionId" to meta.getString("sessionId"),
                    "sessionJson" to meta.getString("sessionJson"),
                    "startedAt" to meta.getLong("startedAt"), "durationMs" to meta.getLong("durationMs"),
                    "bytes" to audio.length(), "format" to meta.getString("format"),
                    "complete" to meta.optBoolean("complete", false)
                )
            } catch (_: Exception) { null }
        } ?: emptyList()

    private fun finishRun() {
        val current = run ?: return
        run = null
        current.finish()
    }

    private inner class Run(val id: String, val sessionJson: String, val bitrate: Int, val noteOwner:String?) {
        val sessionId = JSONObject(sessionJson).getString("id")
        private var part = 0
        private var completedBytes = 0L
        private var completedSamples = 0L
        private var checkpointSamples = 0L
        var encoder = newEncoder()
        private var finished = false

        private fun newEncoder(): PcmFileEncoder {
            check(directory.usableSpace > MIN_FREE_BYTES) { "存储空间不足，已停止录音" }
            if(noteOwner!=null)app.iko.notes.NoteRecordingInbox.checkCapacity(activity,noteOwner)
            val clipId = "${id}_${part++}"
            val output=if(noteOwner!=null) app.iko.notes.NoteRecordingInbox.audioDirectory(activity).apply { mkdirs() } else directory
            val encoder = PcmFileEncoder(output, clipId, bitrate)
            try { writeMeta(encoder, false) }
            catch (e: Exception) {
                try { encoder.finish() } catch (_: Exception) {}
                encoder.file.delete(); AtomicFile(metaFile(clipId)).delete()
                throw e
            }
            return encoder
        }

        fun append(pcm: ByteArray) {
            // Frames are never discarded for being quiet. ASR receives the original stream independently.
            encoder.append(pcm)
            if (encoder.samples - checkpointSamples >= 80000) {
                check(directory.usableSpace > MIN_FREE_BYTES) { "存储空间不足，已停止录音" }
                writeMeta(encoder, false)
                checkpointSamples = encoder.samples
            }
            if (encoder.samples >= 16000L * 900) {
                encoder.finish()
                writeMeta(encoder, true)
                completedSamples += encoder.samples
                completedBytes += encoder.file.length()
                encoder = newEncoder()
                checkpointSamples = 0
            }
        }

        fun stats() = mapOf("durationMs" to ((completedSamples + encoder.samples) / 16),
            "bytes" to (completedBytes + encoder.file.length()))

        fun finish() {
            if (finished) return
            finished = true
            try { encoder.finish() }
            finally {
                if (encoder.samples > 0) writeMeta(encoder, encoder.finished)
                else { encoder.file.delete(); AtomicFile(metaFile(encoder.id)).delete() }
                if(noteOwner!=null)app.iko.notes.NoteRecordingInbox.finished(encoder.id)
            }
        }

        private fun writeMeta(audio: PcmFileEncoder, complete: Boolean) {
            if(noteOwner!=null){app.iko.notes.NoteRecordingInbox.write(activity,noteOwner,audio.file,audio.id,audio.samples/16,audio.startedAt,complete);return}
            val meta = JSONObject().put("id", audio.id).put("sessionId", sessionId)
                .put("sessionJson", sessionJson).put("startedAt", audio.startedAt)
                .put("durationMs", audio.samples / 16).put("format", audio.formatLabel)
                .put("fileName", audio.file.name).put("complete", complete)
            val atomic = AtomicFile(metaFile(audio.id))
            val stream = atomic.startWrite()
            try { stream.write(meta.toString().toByteArray()); atomic.finishWrite(stream) }
            catch (e: Exception) { atomic.failWrite(stream); throw e }
        }
    }

    private fun stopPlayer() {
        player?.release(); player = null; playerReady = false; playerClip = null
    }

    fun onResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != EXPORT_REQUEST) return false
        val result = pendingExport ?: return true
        val file = exportFile
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || file == null) {
            pendingExport = null; exportFile = null; result.success(false); return true
        }
        Thread {
            try {
                activity.contentResolver.openOutputStream(uri)?.use { output ->
                    file.inputStream().use { it.copyTo(output, 65536) }
                } ?: error("无法写入所选文件")
                activity.runOnUiThread {
                    if (pendingExport === result) {
                        pendingExport = null; exportFile = null; result.success(true)
                    }
                }
            } catch (e: Exception) {
                activity.runOnUiThread {
                    if (pendingExport === result) {
                        pendingExport = null; exportFile = null
                        result.error("EXPORT", "导出失败，请重选保存位置", null)
                    }
                }
            }
        }.start()
        return true
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        stopPlayer()
        pendingExport?.success(false); pendingExport = null; exportFile = null
        Thread { synchronized(lock) { closed = true; try { finishRun() } catch (_: Exception) {} } }.start()
    }

    companion object {
        private const val EXPORT_REQUEST = 9414
        private const val MIN_FREE_BYTES = 16L * 1024 * 1024
    }
}

/** Synchronous encoder used solely on the recording task queue, never on the microphone/UI thread. */
private class PcmFileEncoder(directory: File, val id: String, bitrate: Int) {
    val startedAt = System.currentTimeMillis()
    var samples = 0L; private set
    var finished = false; private set
    private var released = false
    private lateinit var codec: MediaCodec
    private lateinit var muxer: MediaMuxer
    lateinit var file: File; private set
    lateinit var formatLabel: String; private set
    private var track = -1
    private val info = MediaCodec.BufferInfo()
    private val frame = ByteArray(640)
    private var frameBytes = 0
    private var submittedSamples = 0L
    private var codecAllocated = false
    private var muxerAllocated = false
    private var firstOutputUs: Long? = null

    init {
        try {
            val opus = Build.VERSION.SDK_INT >= 29
            open(directory, if (opus) bitrate else 16000, opus)
        }
        catch (e: Exception) {
            cleanup(); if (::file.isInitialized) file.delete()
            released = false; track = -1
            try { open(directory, 16000, false) }
            catch (fallback: Exception) { cleanup(); file.delete(); throw fallback }
        }
    }

    private fun open(directory: File, bitrate: Int, opus: Boolean) {
        file = File(directory, "$id.${if (opus) "webm" else "m4a"}")
        val mime = if (opus) MediaFormat.MIMETYPE_AUDIO_OPUS else MediaFormat.MIMETYPE_AUDIO_AAC
        codec = MediaCodec.createEncoderByType(mime)
        codecAllocated = true
        val format = MediaFormat.createAudioFormat(mime, 16000, 1).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 640)
            val caps=codec.codecInfo.getCapabilitiesForType(mime).encoderCapabilities
            if(caps.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR))
                setInteger(MediaFormat.KEY_BITRATE_MODE,MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            if (!opus) setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        muxer = MediaMuxer(file.path, if (opus) MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM
            else MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        muxerAllocated = true
        codec.start()
        formatLabel = if (opus) "Opus · ${bitrate / 1000} kbps" else "AAC · 16 kbps（兼容）"
    }

    fun append(pcm: ByteArray) {
        check(!released) { "编码器已关闭" }
        var offset = 0
        while (offset < pcm.size) {
            val count = minOf(frame.size - frameBytes, pcm.size - offset)
            System.arraycopy(pcm, offset, frame, frameBytes, count)
            frameBytes += count; offset += count
            if (frameBytes == frame.size) { feed(frame, frameBytes, false); frameBytes = 0 }
        }
        samples += pcm.size / 2
    }

    private fun feed(bytes: ByteArray, count: Int, eos: Boolean) {
        val deadline = System.nanoTime() + 1_000_000_000L
        var index: Int
        while (true) {
            index = codec.dequeueInputBuffer(10000)
            if (index >= 0) break
            drain(false)
            check(System.nanoTime() < deadline) { "录音编码超时" }
        }
        val input = codec.getInputBuffer(index) ?: error("无法获取编码缓冲区")
        input.clear(); input.put(bytes, 0, count)
        codec.queueInputBuffer(index, 0, count, submittedSamples * 1_000_000L / 16000,
            if (eos) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
        submittedSamples += count / 2
        if (!eos) drain(false)
    }

    private fun drain(untilEos: Boolean) {
        val deadline = System.nanoTime() + 2_000_000_000L
        while (true) {
            val index = codec.dequeueOutputBuffer(info, if (untilEos) 10000 else 0)
            when {
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    check(track < 0) { "录音格式意外改变" }
                    track = muxer.addTrack(codec.outputFormat); muxer.start()
                }
                index >= 0 -> {
                    val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    try {
                        if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                            check(track >= 0) { "录音容器尚未就绪" }
                            val output = codec.getOutputBuffer(index) ?: error("无法读取编码音频")
                            output.position(info.offset); output.limit(info.offset + info.size)
                            if (firstOutputUs == null) firstOutputUs = info.presentationTimeUs
                            info.presentationTimeUs -= firstOutputUs!!
                            muxer.writeSampleData(track, output, info)
                        }
                    } finally { codec.releaseOutputBuffer(index, false) }
                    if (eos) return
                }
                !untilEos -> return
            }
            check(System.nanoTime() < deadline) { "录音封口超时" }
        }
    }

    fun finish() {
        if (released) return
        try {
            val evenBytes = frameBytes - frameBytes % 2
            if (evenBytes > 0) feed(frame, evenBytes, false)
            feed(frame, 0, true)
            drain(true)
            if (track >= 0) muxer.stop()
            finished = true
        } finally { cleanup() }
    }

    private fun cleanup() {
        released = true
        if (codecAllocated) {
            codecAllocated = false
            try { codec.stop() } catch (_: Exception) {}
            try { codec.release() } catch (_: Exception) {}
        }
        if (muxerAllocated) { muxerAllocated = false; try { muxer.release() } catch (_: Exception) {} }
    }
}
