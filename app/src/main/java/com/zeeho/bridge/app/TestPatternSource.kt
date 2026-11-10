package com.zeeho.bridge.app

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import com.zeeho.bridge.dashlink.FrameSource
import com.zeeho.bridge.dashlink.H264Encoder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.concurrent.thread
import kotlin.math.min
import kotlin.math.sin

/**
 * 里程碑 1 的测试画面：自己的线程按固定帧率画到编码器的 Surface 上，
 * 不依赖屏幕刷新，所以锁屏/息屏也会持续出帧（顺便验证锁屏投屏）。
 * 画面模拟最终风格：深色“地图”底 + 悬浮车速 + 时间日期 + 边缘渐隐的媒体卡片。
 */
class TestPatternSource(
    private val w: Int,
    private val h: Int,
    bitrate: Int,
    private val fps: Int,
    private val log: (String) -> Unit,
) : FrameSource {

    private val encoder = H264Encoder(w, h, bitrate, fps, log)
    @Volatile private var running = false
    private var renderThread: Thread? = null
    private var frameNo = 0L

    private val s = min(w, h).toFloat()            // 尺寸基准
    private val timeFmt = SimpleDateFormat("HH:mm", Locale.CHINA)
    private val dateFmt = SimpleDateFormat("M月d日 EEE", Locale.CHINA)

    private val bg = Paint().apply {
        shader = LinearGradient(0f, 0f, w.toFloat(), h.toFloat(),
            Color.rgb(10, 16, 28), Color.rgb(18, 26, 40), Shader.TileMode.CLAMP)
    }
    private val road = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; color = Color.rgb(46, 58, 78); strokeWidth = s * 0.05f
        strokeCap = Paint.Cap.ROUND
    }
    private val route = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; color = Color.rgb(64, 156, 255); strokeWidth = s * 0.035f
        strokeCap = Paint.Cap.ROUND
    }
    private val vignette = Paint().apply {
        shader = RadialGradient(w / 2f, h / 2f, maxOf(w, h) * 0.75f,
            intArrayOf(Color.TRANSPARENT, Color.TRANSPARENT, Color.argb(220, 0, 0, 0)),
            floatArrayOf(0f, 0.55f, 1f), Shader.TileMode.CLAMP)
    }
    private val speedScrim = Paint()
    private val speedText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE; textSize = s * 0.42f; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        isFakeBoldText = false
    }
    private val unitText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(170, 255, 255, 255); textSize = s * 0.09f
    }
    private val timeText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE; textSize = s * 0.16f; textAlign = Paint.Align.RIGHT
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    }
    private val smallText = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(190, 255, 255, 255); textSize = s * 0.065f
    }
    private val card = Paint(Paint.ANTI_ALIAS_FLAG)
    private val cardEdge = Paint(Paint.ANTI_ALIAS_FLAG)
    private val bar = Paint().apply { color = Color.rgb(64, 156, 255) }
    private val roadPath = Path()

    override fun start() {
        encoder.start()
        running = true
        renderThread = thread(name = "test-pattern", isDaemon = true) { renderLoop() }
    }

    override fun stop() {
        running = false
        renderThread?.join(500)
        encoder.stop()
    }

    override fun requestKeyFrame() = encoder.requestKeyFrame()

    override fun pollFrame(timeoutMs: Long): ByteArray? = encoder.pollFrame(timeoutMs)

    private fun renderLoop() {
        val frameMs = 1000L / fps.coerceIn(5, 60)
        while (running) {
            val t0 = System.currentTimeMillis()
            val c = try { encoder.inputSurface.lockHardwareCanvas() } catch (e: Exception) {
                log("[test] 无法绘制：${e.message}"); break
            }
            try { draw(c, t0) } finally {
                try { encoder.inputSurface.unlockCanvasAndPost(c) } catch (_: Exception) {}
            }
            frameNo++
            val wait = frameMs - (System.currentTimeMillis() - t0)
            if (wait > 0) try { Thread.sleep(wait) } catch (_: InterruptedException) { break }
        }
    }

    private fun draw(c: Canvas, now: Long) {
        val fw = w.toFloat(); val fh = h.toFloat()
        c.drawRect(0f, 0f, fw, fh, bg)

        // “地图”：缓慢移动的道路网，证明画面是活的
        val shift = (now / 30 % 400) / 400f
        for (i in -1..4) {
            val y = fh * (i + shift) / 3.5f
            roadPath.reset()
            roadPath.moveTo(-50f, y)
            roadPath.cubicTo(fw * 0.3f, y - fh * 0.15f, fw * 0.6f, y + fh * 0.15f, fw + 50f, y)
            c.drawPath(roadPath, road)
        }
        for (i in 0..5) {
            val x = fw * (i + shift) / 5f
            c.drawLine(x, -20f, x - fw * 0.1f, fh + 20f, road)
        }
        roadPath.reset()
        roadPath.moveTo(fw * 0.55f, fh + 20f)
        roadPath.cubicTo(fw * 0.5f, fh * 0.7f, fw * 0.75f, fh * 0.45f, fw * 0.68f, fh * 0.1f)
        c.drawPath(roadPath, route)
        c.drawRect(0f, 0f, fw, fh, vignette)

        // 悬浮车速：无边框，靠底下一团柔和暗区和地图融合
        val cx = fw * 0.22f; val cy = fh * 0.5f
        speedScrim.shader = RadialGradient(cx, cy, s * 0.42f,
            intArrayOf(Color.argb(170, 0, 0, 0), Color.TRANSPARENT), null, Shader.TileMode.CLAMP)
        c.drawCircle(cx, cy, s * 0.42f, speedScrim)
        val kmh = Telemetry.speedKmh
        val fresh = System.currentTimeMillis() - Telemetry.lastFixAt < 5000
        val speedStr = if (kmh >= 0 && fresh) kmh.toInt().toString() else "--"
        speedText.textAlign = Paint.Align.CENTER
        c.drawText(speedStr, cx, cy + s * 0.12f, speedText)
        unitText.textAlign = Paint.Align.CENTER
        c.drawText("km/h", cx, cy + s * 0.24f, unitText)

        // 时间 / 日期
        val d = Date(now)
        c.drawText(timeFmt.format(d), fw - s * 0.06f, s * 0.2f, timeText)
        smallText.textAlign = Paint.Align.RIGHT
        c.drawText(dateFmt.format(d), fw - s * 0.06f, s * 0.29f, smallText)

        // 媒体卡片：半透明 + 边缘渐隐
        val r = RectF(fw * 0.52f, fh - s * 0.42f, fw - s * 0.05f, fh - s * 0.08f)
        card.shader = LinearGradient(r.left, r.top, r.right, r.bottom,
            Color.argb(150, 30, 41, 59), Color.argb(90, 15, 23, 42), Shader.TileMode.CLAMP)
        c.drawRoundRect(r, s * 0.05f, s * 0.05f, card)
        cardEdge.shader = RadialGradient(r.centerX(), r.centerY(), r.width() * 0.75f,
            intArrayOf(Color.TRANSPARENT, Color.argb(120, 10, 16, 28)), null, Shader.TileMode.CLAMP)
        c.drawRoundRect(r, s * 0.05f, s * 0.05f, cardEdge)
        smallText.textAlign = Paint.Align.LEFT
        c.drawText("测试画面 · 极核投屏桥", r.left + s * 0.05f, r.top + s * 0.11f, smallText)
        c.drawText("画布 ${w}x$h  帧 #$frameNo", r.left + s * 0.05f, r.top + s * 0.21f, smallText)
        val p = ((sin(now / 600.0) + 1) / 2).toFloat()
        c.drawRect(r.left + s * 0.05f, r.bottom - s * 0.07f,
            r.left + s * 0.05f + (r.width() - s * 0.1f) * p, r.bottom - s * 0.055f, bar)
    }
}
