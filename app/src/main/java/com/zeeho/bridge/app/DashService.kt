package com.zeeho.bridge.app

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.wifi.WifiManager
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import com.zeeho.bridge.dashlink.DashConfig
import com.zeeho.bridge.dashlink.DashListener
import com.zeeho.bridge.dashlink.DashSession
import com.zeeho.bridge.dashlink.DashState

/**
 * 前台服务：持有投屏会话、CPU/WiFi 唤醒锁和 GPS。
 * 投屏画面由自己的线程渲染，不依赖屏幕，所以手机锁屏后仍会持续推流。
 */
class DashService : Service(), DashListener {

    private var session: DashSession? = null
    private var cpuLock: PowerManager.WakeLock? = null
    private var screenLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var gpsListener: LocationListener? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                shutdown()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                if (session != null) return START_STICKY
                val pkg = intent?.getStringExtra(EXTRA_PKG)?.trim().orEmpty().ifEmpty { DashConfig().spoofPackage }
                val keepScreen = intent?.getBooleanExtra(EXTRA_KEEP_SCREEN, false) ?: false
                goForeground("正在连接仪表…")
                acquireLocks(keepScreen)
                startGps()
                val cfg = DashConfig(spoofPackage = pkg)
                LogBus.log("启动投屏，握手包名=$pkg")
                session = DashSession(this, cfg, { w, h ->
                    LogBus.log("创建测试画面 ${w}x$h")
                    TestPatternSource(w, h, cfg.bitrate, cfg.fps, LogBus::log)
                }, this).also { it.start() }
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        shutdown()
        super.onDestroy()
    }

    private fun shutdown() {
        session?.stop()
        session = null
        stopGps()
        runCatching { cpuLock?.takeIf { it.isHeld }?.release() }
        runCatching { screenLock?.takeIf { it.isHeld }?.release() }
        runCatching { wifiLock?.takeIf { it.isHeld }?.release() }
        cpuLock = null; screenLock = null; wifiLock = null
        LogBus.setStatus("已停止")
    }

    // ---------------------------------------------------------------- DashListener

    override fun onLog(line: String) = LogBus.log(line)

    override fun onState(state: DashState, detail: String) {
        val text = when (state) {
            DashState.IDLE -> "空闲"
            DashState.SEARCHING -> "等待仪表热点"
            DashState.PROBING -> "探测仪表"
            DashState.HANDSHAKE -> "握手中"
            DashState.STREAMING -> "投屏中"
            DashState.ERROR -> "出错"
            DashState.STOPPED -> "已停止"
        } + if (detail.isNotEmpty()) "（$detail）" else ""
        LogBus.setStatus(text)
        if (state != DashState.STOPPED) updateNotification(text)
    }

    override fun onTouch(action: Int, x: Int, y: Int, pointerId: Int) {
        LogBus.log("仪表触摸 action=$action ($x,$y) id=$pointerId")
    }

    // ---------------------------------------------------------------- 前台通知

    private fun goForeground(text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "投屏状态", NotificationManager.IMPORTANCE_LOW))
        var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        if (hasLocation()) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
        startForeground(NOTIF_ID, buildNotification(text), type)
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIF_ID, buildNotification(text))
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 1, Intent(this, DashService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("极核投屏桥")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "停止", stop).build())
            .build()
    }

    // ---------------------------------------------------------------- 唤醒锁

    @SuppressLint("WakelockTimeout")
    private fun acquireLocks(keepScreen: Boolean) {
        val pm = getSystemService(PowerManager::class.java)
        cpuLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ZeehoBridge:cpu").apply {
            setReferenceCounted(false); acquire()
        }
        if (keepScreen) {
            @Suppress("DEPRECATION")
            screenLock = pm.newWakeLock(PowerManager.SCREEN_DIM_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "ZeehoBridge:screen").apply { setReferenceCounted(false); acquire() }
        }
        val wm = applicationContext.getSystemService(WifiManager::class.java)
        @Suppress("DEPRECATION")
        wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "ZeehoBridge:wifi").apply {
            setReferenceCounted(false); acquire()
        }
    }

    // ---------------------------------------------------------------- GPS 车速

    private fun hasLocation() =
        checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    private fun startGps() {
        if (!hasLocation()) { LogBus.log("没有定位权限，车速显示 --"); return }
        val lm = getSystemService(LocationManager::class.java)
        val l = LocationListener { loc: Location ->
            if (loc.hasSpeed()) {
                Telemetry.speedKmh = loc.speed * 3.6f
                Telemetry.lastFixAt = System.currentTimeMillis()
            }
        }
        runCatching {
            lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 500L, 0f, l, Looper.getMainLooper())
            gpsListener = l
        }.onFailure { LogBus.log("GPS 启动失败：${it.message}") }
    }

    private fun stopGps() {
        gpsListener?.let { getSystemService(LocationManager::class.java).removeUpdates(it) }
        gpsListener = null
    }

    companion object {
        private const val CHANNEL = "dash"
        private const val NOTIF_ID = 1
        const val ACTION_START = "start"
        const val ACTION_STOP = "stop"
        const val EXTRA_PKG = "pkg"
        const val EXTRA_KEEP_SCREEN = "keepScreen"

        fun start(ctx: Context, pkg: String, keepScreen: Boolean) {
            ctx.startForegroundService(Intent(ctx, DashService::class.java).setAction(ACTION_START)
                .putExtra(EXTRA_PKG, pkg).putExtra(EXTRA_KEEP_SCREEN, keepScreen))
        }

        fun stop(ctx: Context) {
            ctx.startService(Intent(ctx, DashService::class.java).setAction(ACTION_STOP))
        }
    }
}
