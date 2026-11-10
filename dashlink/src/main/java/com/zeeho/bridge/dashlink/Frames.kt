package com.zeeho.bridge.dashlink

import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 控制面帧（端口 10922 与仪表探测端口 10930）：16 字节小端包头 + 负载。
 *   [0..3]  cmd
 *   [4..7]  totalLen = 16 + payload.size
 *   [8..11] magic    = cmd XOR totalLen
 *   [12..15] 保留 0
 */
class CtrlFrame(val cmd: Int, val payload: ByteArray = EMPTY) {

    val cmdHex: String get() = "0x" + cmd.toUInt().toString(16)

    fun text(): String = if (payload.isEmpty()) "" else String(payload, Charsets.UTF_8)

    fun write(out: OutputStream) {
        val totalLen = 16 + payload.size
        val h = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
        h.putInt(0, cmd)
        h.putInt(4, totalLen)
        h.putInt(8, cmd xor totalLen)
        synchronized(out) {
            out.write(h.array())
            if (payload.isNotEmpty()) out.write(payload)
            out.flush()
        }
    }

    companion object {
        val EMPTY = ByteArray(0)

        // 通道选择（仪表回连 10922 后发的第一帧），应答 = cmd + 1
        const val CH_CAR_CTRL = 0x10000
        const val CH_CAR_DATA = 0x20000

        const val MDNS_RESPOND = 0x70000010      // 手机 → 仪表:10930 探测
        const val MDNS_RESPOND_ACK = 0x70000011  // 仪表 → 手机 {"status":true}
        const val HEARTBEAT = 0x70000000
        const val HEARTBEAT_ACK = 0x70000001

        const val CLIENT_INFO = 0x10010          // 仪表 → 手机（JSON）
        const val CLIENT_INFO_RLY = 0x10011      // 手机 → 仪表（JSON）
        const val QUERY_SPEED = 0x10690
        const val CHECK_SN = 0x103e0
        const val CHECK_SN_RESULT = 0x201c0
        const val HU_TIME_SYNC = 0x10600         // 仪表每 ~2s 发一次，应答 0x10601

        fun readFully(input: InputStream, buf: ByteArray, len: Int): Boolean {
            var read = 0
            while (read < len) {
                val n = input.read(buf, read, len - read)
                if (n <= 0) return false
                read += n
            }
            return true
        }

        /** 读一帧；EOF 返回 null；包头校验失败抛异常。 */
        fun read(input: InputStream): CtrlFrame? {
            val header = ByteArray(16)
            if (!readFully(input, header, 16)) return null
            val b = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
            val cmd = b.getInt(0)
            val totalLen = b.getInt(4)
            val magic = b.getInt(8)
            check((cmd xor totalLen) == magic) { "bad magic cmd=$cmd len=$totalLen magic=$magic" }
            val len = (totalLen - 16).coerceAtLeast(0)
            check(len <= 4 * 1024 * 1024) { "payload too large: $len" }
            val payload = ByteArray(len)
            if (len > 0 && !readFully(input, payload, len)) throw IllegalStateException("short payload")
            return CtrlFrame(cmd, payload)
        }
    }
}

/**
 * 媒体面帧（端口 10921 控制 / 10920 数据）：8 字节小端包头 + 负载。
 *   cmdType(s16) | cmdLen(u16) | token(i32)
 */
object MediaFrame {
    const val REQ_CONFIG_CAPTURE = 16
    const val RLY_CONFIG_CAPTURE = 17
    const val REQ_TOUCH = 32
    const val REQ_GET_VERSION = 48
    const val REQ_HEARTBEAT = 64
    const val REQ_CONFIG_CAPTURE_EXTEND = 96
    const val REQ_DATA_START = 112
    const val REQ_DATA_NEXT = 114
    const val REQ_START_H264 = 128

    class Req(val cmdType: Int, val token: Int, val body: ByteArray)

    fun read(input: InputStream): Req? {
        val h = ByteArray(8)
        if (!CtrlFrame.readFully(input, h, 8)) return null
        val b = ByteBuffer.wrap(h).order(ByteOrder.LITTLE_ENDIAN)
        val cmdType = b.getShort(0).toInt()
        val len = b.getShort(2).toInt() and 0xFFFF
        val token = b.getInt(4)
        val body = ByteArray(len)
        if (len > 0 && !CtrlFrame.readFully(input, body, len)) return null
        return Req(cmdType, token, body)
    }

    fun write(out: OutputStream, cmdType: Int, body: ByteArray? = null) {
        val len = body?.size ?: 0
        val h = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
        h.putShort(0, cmdType.toShort())
        h.putShort(2, len.toShort())
        h.putInt(4, 0)
        synchronized(out) {
            out.write(h.array())
            if (len > 0) out.write(body!!)
            out.flush()
        }
    }

    /** 视频帧在数据口上是“裸写”：[长度 i32 LE][H.264 Annex-B 访问单元]。 */
    fun writeVideo(out: OutputStream, accessUnit: ByteArray) {
        val sz = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(0, accessUnit.size).array()
        synchronized(out) {
            out.write(sz)
            out.write(accessUnit)
            out.flush()
        }
    }
}
