package com.zeeho.bridge.dashlink

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * 与 MotoPlay（Carbit EasyConn / PXC）仪表的一次投屏会话。
 *
 * 前提：手机已经在系统设置里连上仪表热点（不需要极核 App）。流程：
 *  1. 找到 WiFi 网络，网关就是仪表；
 *  2. 本机在 10920/10921/10922 开 TCP 服务（手机是服务端）；
 *  3. 连一次仪表 :10930 发探测，仪表接受后主动回连上面三个端口；
 *  4. 10922 走控制面握手，10921 协商画布尺寸，10920 由仪表逐帧拉取 H.264。
 * 所有连接断开后会自动重新探测，直到 [stop]。
 */
class DashSession(
    private val context: Context,
    private val config: DashConfig,
    private val sourceFactory: (width: Int, height: Int) -> FrameSource,
    private val listener: DashListener,
) {
    @Volatile private var running = false
    private val servers = CopyOnWriteArrayList<ServerSocket>()
    private val clients = CopyOnWriteArrayList<Socket>()
    private val liveConns = AtomicInteger(0)
    private val sourceLock = Any()
    private val phoneUuid = UUID.randomUUID().toString()

    @Volatile private var network: Network? = null
    @Volatile private var dashIp: Inet4Address? = null
    @Volatile private var source: FrameSource? = null
    @Volatile private var canvasW = 0
    @Volatile private var canvasH = 0
    @Volatile private var framesSent = 0L
    @Volatile var state: DashState = DashState.IDLE
        private set

    fun start() {
        if (running) return
        running = true
        thread(name = "dash-main", isDaemon = true) {
            try { runMain() } catch (e: Exception) {
                log("!! 会话异常：$e"); setState(DashState.ERROR, e.message ?: "")
            }
        }
    }

    fun stop() {
        running = false
        servers.forEach { runCatching { it.close() } }
        clients.forEach { runCatching { it.close() } }
        servers.clear(); clients.clear()
        stopSource()
        setState(DashState.STOPPED)
    }

    // ---------------------------------------------------------------- 主流程

    private class Link(val network: Network, val local: Inet4Address, val gateway: Inet4Address)

    private fun runMain() {
        setState(DashState.SEARCHING, "等待连接仪表热点")
        var link: Link? = null
        while (running && link == null) {
            link = findWifiLink()
            if (link == null) {
                log("没找到已连接的 WiFi，请先在系统设置里连上仪表热点")
                sleep(3000)
            }
        }
        if (!running || link == null) return
        network = link.network
        dashIp = link.gateway
        log("WiFi 已连接：本机 ${link.local.hostAddress}，仪表（网关）${link.gateway.hostAddress}")

        try {
            for (port in intArrayOf(PORT_DATA, PORT_MEDIA_CTRL, PORT_PXC)) openServer(link.local, port)
        } catch (e: Exception) {
            log("!! 无法监听端口：${e.message}。如果极核/春风官方 App 在后台运行，请先强行停止它（它占用同样的端口）")
            setState(DashState.ERROR, "端口被占用")
            return
        }

        var attempt = 0
        while (running) {
            if (liveConns.get() > 0) { attempt = 0; sleep(1000); continue }
            setState(DashState.PROBING, "第 ${attempt + 1} 次探测")
            attempt++
            if (probeOnce()) {
                setState(DashState.HANDSHAKE, "等待仪表回连")
                val deadline = System.currentTimeMillis() + 10_000
                while (running && liveConns.get() == 0 && System.currentTimeMillis() < deadline) sleep(200)
                if (liveConns.get() == 0) log("仪表接受了探测但 10 秒内没有回连，重试")
            } else {
                sleep(minOf(1000L * attempt, 5000L))
            }
        }
    }

    private fun findWifiLink(): Link? {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return null
        @Suppress("DEPRECATION")
        for (n in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(n) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            val lp = cm.getLinkProperties(n) ?: continue
            val la = lp.linkAddresses.firstOrNull { it.address is Inet4Address } ?: continue
            val local = la.address as Inet4Address
            val gw = lp.routes.firstOrNull { r ->
                r.isDefaultRoute && r.gateway is Inet4Address && !r.gateway!!.isAnyLocalAddress
            }?.gateway as Inet4Address? ?: subnetFirstHost(local, la.prefixLength)
            return Link(n, local, gw)
        }
        return null
    }

    private fun subnetFirstHost(addr: Inet4Address, prefix: Int): Inet4Address {
        val ip = ByteBuffer.wrap(addr.address).int
        val mask = if (prefix == 0) 0 else (-1 shl (32 - prefix))
        val first = (ip and mask) + 1
        return InetAddress.getByAddress(ByteBuffer.allocate(4).putInt(first).array()) as Inet4Address
    }

    private fun openServer(local: Inet4Address, port: Int) {
        val ss = ServerSocket()
        ss.reuseAddress = true
        ss.bind(InetSocketAddress(local, port), 4)
        servers += ss
        thread(name = "dash-accept-$port", isDaemon = true) {
            while (running) {
                val s = try { ss.accept() } catch (e: Exception) { break }
                s.tcpNoDelay = true
                clients += s
                liveConns.incrementAndGet()
                log("[:$port] 仪表已连接 ${s.remoteSocketAddress}")
                thread(name = "dash-conn-$port", isDaemon = true) {
                    try {
                        if (port == PORT_PXC) ctrlLoop(s) else mediaLoop(port, s)
                    } catch (e: Exception) {
                        if (running) log("[:$port] 连接异常：${e.message}")
                    } finally {
                        runCatching { s.close() }
                        clients -= s
                        if (liveConns.decrementAndGet() == 0) onAllClosed()
                    }
                }
            }
        }
    }

    private fun onAllClosed() {
        if (!running) return
        log("仪表连接全部断开（熄火、超时或切换界面），准备重新探测")
        stopSource()
        canvasW = 0; canvasH = 0
    }

    private fun probeOnce(): Boolean {
        val ip = dashIp ?: return false
        return try {
            val sock = network?.socketFactory?.createSocket() ?: Socket()
            sock.use { s ->
                s.connect(InetSocketAddress(ip, PORT_PROBE), 3000)
                s.soTimeout = 5000
                val json = JSONObject().put("phoneType", "Android").put("packageName", config.spoofPackage)
                log("[probe] → ${ip.hostAddress}:$PORT_PROBE $json")
                CtrlFrame(CtrlFrame.MDNS_RESPOND, json.toString().toByteArray()).write(s.getOutputStream())
                val r = CtrlFrame.read(s.getInputStream())
                val ok = r != null && r.cmd == CtrlFrame.MDNS_RESPOND_ACK && r.text().contains("true")
                log("[probe] ← ${r?.cmdHex} ${r?.text()} ${if (ok) "（已接受）" else "（未接受）"}")
                if (r != null && !ok) {
                    log("提示：仪表拒绝了探测，可能需要换成极核官方 App 的包名（界面里可修改）")
                }
                ok
            }
        } catch (e: Exception) {
            log("[probe] 失败：${e.javaClass.simpleName} ${e.message}")
            false
        }
    }

    // ---------------------------------------------------------------- 控制面（10922）

    private fun ctrlLoop(s: Socket) {
        val input = BufferedInputStream(s.getInputStream())
        val out = s.getOutputStream()
        var first = true
        while (running) {
            val f = CtrlFrame.read(input) ?: return
            if (first) {
                first = false
                if (f.cmd != CtrlFrame.CH_CAR_CTRL && f.cmd != CtrlFrame.CH_CAR_DATA) {
                    log("⚠ 第一帧 ${f.cmdHex} 不是标准通道选择。这台仪表可能使用 MCULite/ECTinyPlus 变体协议，请保存日志用于分析")
                }
            }
            handleCtrl(f, s, out)
        }
    }

    private fun handleCtrl(f: CtrlFrame, s: Socket, out: OutputStream) {
        when (f.cmd) {
            CtrlFrame.CH_CAR_CTRL, CtrlFrame.CH_CAR_DATA -> {
                val name = if (f.cmd == CtrlFrame.CH_CAR_CTRL) "CAR_CTRL" else "CAR_DATA"
                log("[ctrl] 仪表选择通道 $name")
                CtrlFrame(f.cmd + 1).write(out)
                startHeartbeat(s, name)
            }
            CtrlFrame.CLIENT_INFO -> onClientInfo(f, out)
            CtrlFrame.CHECK_SN -> {
                val sn = runCatching { JSONObject(f.text()).optString("sn") }.getOrDefault("")
                CtrlFrame(CtrlFrame.CHECK_SN + 1).write(out)
                val result = JSONObject()
                    .put("isOk", true).put("errCode", 0).put("errMsg", "")
                    .put("id", sn).put("client_set", "easy_conn")
                CtrlFrame(CtrlFrame.CHECK_SN_RESULT, result.toString().toByteArray()).write(out)
                log("[ctrl] CHECK_SN 通过")
            }
            CtrlFrame.HEARTBEAT -> CtrlFrame(CtrlFrame.HEARTBEAT_ACK).write(out)
            // 原样回显仪表自己的时间，避免把仪表时钟改乱
            CtrlFrame.HU_TIME_SYNC -> CtrlFrame(CtrlFrame.HU_TIME_SYNC + 1, f.payload).write(out)
            else -> {
                if ((f.cmd and 1) == 1) return // 奇数号是仪表对我们的应答，不再回复
                log("[ctrl] ${f.cmdHex} len=${f.payload.size} ${f.text().take(200)} → 应答 cmd+1")
                CtrlFrame(f.cmd + 1).write(out)
            }
        }
    }

    private fun onClientInfo(f: CtrlFrame, out: OutputStream) {
        val text = f.text()
        log("[ctrl] 仪表信息 CLIENT_INFO：$text")
        listener.onClientInfo(text)
        val info = runCatching { JSONObject(text) }.getOrElse { JSONObject() }
        val huid = info.optString("HUID").ifEmpty { info.optString("huid") }
        val reply = JSONObject().apply {
            put("pxcVersion", "1.0.2")
            put("phoneUUID", phoneUuid)
            put("phoneBrand", android.os.Build.BRAND)
            put("phoneModel", android.os.Build.MODEL)
            put("phoneOsVersion", android.os.Build.VERSION.SDK_INT.toString())
            put("phoneOs", "Android")
            put("package", config.spoofPackage)
            put("versionCode", config.versionCode)
            put("token", 0)
            put("pubkey", RsaIdentity.publicKeyBase64)
            put("encryptedHUID", if (huid.isNotEmpty()) RsaIdentity.signHuid(huid) else "")
            put("bluetoothName", config.bluetoothName)
            put("supportH264IFrame", true)
            put("supportFunction", info.optInt("supportFunction", 0))
            put("supportSyncCorrectTime", false)
        }
        CtrlFrame(CtrlFrame.CLIENT_INFO_RLY, reply.toString().toByteArray()).write(out)
        log("[ctrl] 已回复手机信息（HUID=${huid.ifEmpty { "无" }}）")
    }

    /** 部分仪表自己不发心跳，空闲约 7 秒就断，所以每个控制通道都主动发。 */
    private fun startHeartbeat(s: Socket, label: String) {
        thread(name = "dash-hb-$label", isDaemon = true) {
            val out = runCatching { s.getOutputStream() }.getOrNull() ?: return@thread
            while (running && !s.isClosed) {
                sleep(HEARTBEAT_MS)
                if (!running || s.isClosed) break
                try { CtrlFrame(CtrlFrame.HEARTBEAT).write(out) } catch (e: Exception) { break }
            }
        }
    }

    // ---------------------------------------------------------------- 媒体面（10921 / 10920）

    private fun mediaLoop(port: Int, s: Socket) {
        val input = BufferedInputStream(s.getInputStream())
        val out = s.getOutputStream()
        while (running) {
            val r = MediaFrame.read(input) ?: return
            handleMedia(port, r, out)
        }
    }

    private fun handleMedia(port: Int, r: MediaFrame.Req, out: OutputStream) {
        val body = r.body
        when (r.cmdType) {
            MediaFrame.REQ_CONFIG_CAPTURE -> {
                val b = ByteBuffer.wrap(body).order(ByteOrder.LITTLE_ENDIAN)
                val w = if (body.size >= 2) b.getShort(0).toInt() and 0xFFFF else 0
                val h = if (body.size >= 4) b.getShort(2).toInt() and 0xFFFF else 0
                val fps = if (body.size >= 8) b.getInt(4) else 0
                val enc = if (body.size >= 12) b.getInt(8) else 2
                val ext = if (body.size >= 30) body[29] else 0
                canvasW = w and 0xFFF0
                canvasH = h and 0xFFF0
                log("[media] 仪表请求画布 ${w}x$h fps=$fps → 协商 ${canvasW}x$canvasH")
                listener.onCanvas(canvasW, canvasH)
                val rly = ByteBuffer.allocate(9).order(ByteOrder.LITTLE_ENDIAN)
                rly.putInt(0, if (enc == 0) 2 else enc)
                rly.putShort(4, canvasW.toShort())
                rly.putShort(6, canvasH.toShort())
                rly.put(8, ext)
                MediaFrame.write(out, MediaFrame.RLY_CONFIG_CAPTURE, rly.array())
            }
            MediaFrame.REQ_GET_VERSION -> {
                val v = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putInt(0, 3).putInt(4, 1)
                MediaFrame.write(out, MediaFrame.REQ_GET_VERSION + 1, v.array())
            }
            MediaFrame.REQ_HEARTBEAT -> MediaFrame.write(out, MediaFrame.REQ_HEARTBEAT + 1)
            MediaFrame.REQ_CONFIG_CAPTURE_EXTEND ->
                MediaFrame.write(out, MediaFrame.REQ_CONFIG_CAPTURE_EXTEND + 1, "{\"state\":0}".toByteArray())
            MediaFrame.REQ_START_H264 -> MediaFrame.write(out, MediaFrame.REQ_START_H264 + 1)
            MediaFrame.REQ_DATA_START -> {
                ensureSource().requestKeyFrame()
                MediaFrame.write(out, MediaFrame.REQ_DATA_START + 1)
                framesSent = 0
                setState(DashState.STREAMING, "${canvasW}x$canvasH")
                log("[media] 仪表开始拉流")
            }
            MediaFrame.REQ_DATA_NEXT -> {
                val src = ensureSource()
                var frame: ByteArray? = null
                while (running && frame == null) frame = src.pollFrame(500)
                if (frame != null) {
                    MediaFrame.writeVideo(out, frame)
                    framesSent++
                    if (framesSent <= 3 || framesSent % 300 == 0L) log("[media] 已发送第 $framesSent 帧（${frame.size} 字节）")
                }
            }
            MediaFrame.REQ_TOUCH -> if (body.size >= 8) {
                val b = ByteBuffer.wrap(body).order(ByteOrder.LITTLE_ENDIAN)
                val action = when (b.getShort(0).toInt() and 0xFFFF) { 2 -> 0; 1 -> 1; 3 -> 2; else -> -1 }
                if (action >= 0) {
                    listener.onTouch(action, b.getShort(2).toInt() and 0xFFFF,
                        b.getShort(4).toInt() and 0xFFFF, b.getShort(6).toInt() and 0xFFFF)
                }
            }
            else -> log("[media:$port] 未知 cmdType=${r.cmdType} len=${body.size}")
        }
    }

    private fun ensureSource(): FrameSource = synchronized(sourceLock) {
        source ?: run {
            if (canvasW == 0 || canvasH == 0) {
                log("⚠ 仪表没有先声明画布尺寸，暂用 800x384")
                canvasW = 800; canvasH = 384
            }
            sourceFactory(canvasW, canvasH).also { it.start(); source = it }
        }
    }

    private fun stopSource() = synchronized(sourceLock) {
        source?.let { runCatching { it.stop() } }
        source = null
    }

    // ---------------------------------------------------------------- 工具

    private fun setState(s: DashState, detail: String = "") {
        state = s
        listener.onState(s, detail)
    }

    private fun log(line: String) = listener.onLog(line)

    private fun sleep(ms: Long) = try { Thread.sleep(ms) } catch (_: InterruptedException) {}

    companion object {
        const val PORT_DATA = 10920
        const val PORT_MEDIA_CTRL = 10921
        const val PORT_PXC = 10922
        const val PORT_PROBE = 10930
        private const val HEARTBEAT_MS = 2000L
    }
}
