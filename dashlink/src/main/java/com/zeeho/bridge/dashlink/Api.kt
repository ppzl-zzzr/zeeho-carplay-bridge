package com.zeeho.bridge.dashlink

import android.util.Base64
import java.security.KeyPairGenerator
import javax.crypto.Cipher

/** 投屏参数。spoofPackage 是握手时报给仪表的“官方 App 包名”，仪表可能按白名单校验。 */
data class DashConfig(
    val spoofPackage: String = "com.cfmoto.cfmotointernational",
    val versionCode: Int = 126,
    val bluetoothName: String = "ZeehoBridge",
    val bitrate: Int = 2_500_000,
    val fps: Int = 30,
)

/** 视频来源：测试画面、CarPlay 转码等都实现这个接口。帧必须是 H.264 Annex-B，关键帧前带 SPS/PPS。 */
interface FrameSource {
    fun start()
    fun stop()
    fun requestKeyFrame()
    fun pollFrame(timeoutMs: Long): ByteArray?
}

/** 会话事件回调（在后台线程调用）。 */
interface DashListener {
    fun onLog(line: String) {}
    fun onState(state: DashState, detail: String = "") {}
    /** 仪表声明的画布尺寸（已向下取整到 16 的倍数）。 */
    fun onCanvas(width: Int, height: Int) {}
    /** 仪表触屏：action 0=按下 1=抬起 2=移动，坐标为画布坐标。 */
    fun onTouch(action: Int, x: Int, y: Int, pointerId: Int) {}
    /** 握手时仪表发来的 CLIENT_INFO 原文（含型号、分辨率能力等，排查用）。 */
    fun onClientInfo(json: String) {}
}

enum class DashState { IDLE, SEARCHING, PROBING, HANDSHAKE, STREAMING, ERROR, STOPPED }

/**
 * 握手用的 RSA 身份：公钥放进 CLIENT_INFO，HUID 用私钥“加密”（即签名）回传。
 * 与官方 SDK 一致，每次启动生成 1024 位密钥对。
 */
internal object RsaIdentity {
    private val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(1024) }.generateKeyPair()
    val publicKeyBase64: String = Base64.encodeToString(pair.public.encoded, Base64.NO_WRAP)

    fun signHuid(huid: String): String {
        val c = Cipher.getInstance("RSA/ECB/PKCS1Padding")
        c.init(Cipher.ENCRYPT_MODE, pair.private)
        return Base64.encodeToString(c.doFinal(huid.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    }
}
