package com.zeeho.bridge.app

import android.os.Handler
import android.os.Looper
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList

/** 进程内日志与状态总线：服务写，界面读。 */
object LogBus {
    interface Observer {
        fun onLine(line: String)
        fun onStatus(status: String)
    }

    private val main = Handler(Looper.getMainLooper())
    private val fmt = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    private val lines = ArrayDeque<String>()
    private val observers = CopyOnWriteArrayList<Observer>()

    @Volatile var status: String = "未启动"
        private set

    fun log(msg: String) {
        val line = "${fmt.format(Date())} $msg"
        android.util.Log.i("ZeehoBridge", msg)
        synchronized(lines) {
            lines.addLast(line)
            while (lines.size > 800) lines.removeFirst()
        }
        main.post { observers.forEach { it.onLine(line) } }
    }

    fun setStatus(s: String) {
        status = s
        main.post { observers.forEach { it.onStatus(s) } }
    }

    fun snapshot(): List<String> = synchronized(lines) { lines.toList() }

    fun observe(o: Observer) { observers += o }
    fun remove(o: Observer) { observers -= o }
}

/** 手机 GPS 数据，渲染层直接读取。 */
object Telemetry {
    @Volatile var speedKmh: Float = -1f
    @Volatile var lastFixAt: Long = 0L
}
