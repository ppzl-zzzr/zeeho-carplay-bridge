package com.zeeho.bridge.dashlink

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Bundle
import android.view.Surface
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * 仪表能解的 H.264 编码器（输入是 Surface，谁往 [inputSurface] 上画都行）。
 *
 * 关键点（来自 open-cfmoto 实车验证）：
 *  - Baseline @ Level 3.1：仪表上的嵌入式解码器经常只认 Baseline；
 *  - KEY_REPEAT_PREVIOUS_FRAME_AFTER：画面静止时也持续出帧，否则仪表 ~9 秒没帧就断开；
 *  - 关键帧前拼上 SPS/PPS，仪表中途接入也能马上解码；
 *  - 队列满时整体清空并等下一个关键帧，绝不丢掉单个 P 帧（否则会花屏到下一个 IDR）。
 */
class H264Encoder(
    private val width: Int,
    private val height: Int,
    private val bitrate: Int,
    private val fps: Int,
    private val log: (String) -> Unit,
) {
    lateinit var inputSurface: Surface
        private set

    private var codec: MediaCodec? = null
    private val queue = LinkedBlockingDeque<ByteArray>(QUEUE_CAPACITY)
    @Volatile private var spsPps: ByteArray? = null
    @Volatile private var waitKey = true
    @Volatile private var running = false
    private var drainThread: Thread? = null

    fun start() {
        val c = MediaCodec.createEncoderByType(MIME)
        try {
            c.configure(format(baseline = true), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        } catch (e: Exception) {
            log("[enc] Baseline 配置失败，改用默认 profile：${e.message}")
            c.reset()
            c.configure(format(baseline = false), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        }
        inputSurface = c.createInputSurface()
        c.start()
        codec = c
        running = true
        drainThread = thread(name = "h264-drain", isDaemon = true) { drain(c) }
        log("[enc] 编码器启动 ${width}x$height ${bitrate / 1000}kbps ${fps}fps")
    }

    private fun format(baseline: Boolean) = MediaFormat.createVideoFormat(MIME, width, height).apply {
        setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
        setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
        setInteger(MediaFormat.KEY_FRAME_RATE, fps)
        setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, REPEAT_AFTER_US)
        if (baseline) {
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
            setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel31)
        }
    }

    private fun drain(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (running) {
            val idx = try { c.dequeueOutputBuffer(info, 10_000) } catch (e: IllegalStateException) { break }
            if (idx < 0) continue
            val buf = try { c.getOutputBuffer(idx) } catch (e: IllegalStateException) { break }
            if (buf != null && info.size > 0) {
                val data = ByteArray(info.size)
                buf.position(info.offset)
                buf.limit(info.offset + info.size)
                buf.get(data)
                if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                    spsPps = data
                } else {
                    enqueue(data, (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0)
                }
            }
            try { c.releaseOutputBuffer(idx, false) } catch (e: IllegalStateException) { break }
            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
        }
    }

    private fun enqueue(data: ByteArray, key: Boolean) {
        if (waitKey && !key) return
        val frame = if (key) (spsPps?.let { it + data } ?: data) else data
        if (key) waitKey = false
        if (!queue.offerLast(frame)) {
            // 仪表拉得比编码慢：整体清空，从这一帧（若是关键帧）或下一个关键帧重新开始
            queue.clear()
            if (key) queue.offerLast(frame) else requestKeyFrame()
        }
    }

    /** 清空积压并立刻要一个关键帧（仪表开始拉流 / 重连时调用）。 */
    fun requestKeyFrame() {
        queue.clear()
        waitKey = true
        try {
            codec?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (_: Exception) {
        }
    }

    fun pollFrame(timeoutMs: Long): ByteArray? = queue.pollFirst(timeoutMs, TimeUnit.MILLISECONDS)

    fun stop() {
        running = false
        drainThread?.join(500)
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        codec = null
        if (::inputSurface.isInitialized) inputSurface.release()
        queue.clear()
    }

    companion object {
        private const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val QUEUE_CAPACITY = 8
        private const val REPEAT_AFTER_US = 100_000L
    }
}
