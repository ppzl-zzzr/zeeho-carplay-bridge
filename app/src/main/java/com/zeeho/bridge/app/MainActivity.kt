package com.zeeho.bridge.app

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import com.zeeho.bridge.dashlink.DashConfig

/** 调试界面：填握手包名、启动/停止投屏、看日志。真正干活的是 [DashService]。 */
class MainActivity : Activity(), LogBus.Observer {

    private lateinit var statusView: TextView
    private lateinit var logView: TextView
    private lateinit var logScroll: ScrollView
    private lateinit var pkgInput: EditText
    private lateinit var keepScreen: CheckBox

    private val prefs by lazy { getSharedPreferences("bridge", Context.MODE_PRIVATE) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = dp(16)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(12, 18, 30))
            setPadding(pad, pad, pad, pad)
        }
        root.setOnApplyWindowInsetsListener { v, insets ->
            @Suppress("DEPRECATION")
            v.setPadding(pad + insets.systemWindowInsetLeft, pad + insets.systemWindowInsetTop,
                pad + insets.systemWindowInsetRight, pad + insets.systemWindowInsetBottom)
            insets
        }

        root.addView(text("极核投屏桥", 22f, bold = true))
        root.addView(text("先在系统设置里连上仪表热点（不用打开极核 App），再点“开始投屏”。", 13f, alpha = 170))

        statusView = text("状态：${LogBus.status}", 16f, bold = true).apply { setPadding(0, dp(12), 0, dp(8)) }
        root.addView(statusView)

        root.addView(text("握手包名（仪表拒绝探测时，换成极核官方 App 的包名）", 13f, alpha = 170))
        pkgInput = EditText(this).apply {
            setText(prefs.getString("pkg", DashConfig().spoofPackage))
            setTextColor(Color.WHITE); textSize = 14f
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            isSingleLine = true
        }
        root.addView(pkgInput, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))

        keepScreen = CheckBox(this).apply {
            text = "投屏时保持屏幕常亮（专用手机推荐；平时用的手机可不勾，锁屏也能投）"
            setTextColor(Color.WHITE); textSize = 13f
            isChecked = prefs.getBoolean("keepScreen", false)
        }
        root.addView(keepScreen)

        val buttons = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        buttons.addView(button("开始投屏") { onStartClicked() }, weightParams())
        buttons.addView(button("停止") { DashService.stop(this) }, weightParams())
        buttons.addView(button("复制日志") { copyLog() }, weightParams())
        root.addView(buttons)

        logView = TextView(this).apply {
            setTextColor(Color.rgb(190, 205, 225)); textSize = 11f
            typeface = Typeface.MONOSPACE; setTextIsSelectable(true)
        }
        logScroll = ScrollView(this).apply {
            addView(logView)
            setBackgroundColor(Color.rgb(6, 10, 18))
            setPadding(dp(8), dp(8), dp(8), dp(8))
        }
        root.addView(logScroll, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f).apply { topMargin = dp(12) })
        setContentView(root)
    }

    override fun onStart() {
        super.onStart()
        LogBus.observe(this)
        logView.text = LogBus.snapshot().joinToString("\n")
        statusView.text = "状态：${LogBus.status}"
        scrollToEnd()
    }

    override fun onStop() {
        LogBus.remove(this)
        super.onStop()
    }

    override fun onLine(line: String) {
        logView.append(if (logView.length() == 0) line else "\n$line")
        if (logView.lineCount > 1200) logView.text = LogBus.snapshot().joinToString("\n")
        scrollToEnd()
    }

    override fun onStatus(status: String) {
        statusView.text = "状态：$status"
    }

    private fun onStartClicked() {
        prefs.edit().putString("pkg", pkgInput.text.toString().trim())
            .putBoolean("keepScreen", keepScreen.isChecked).apply()
        val needed = buildList {
            if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PERMISSION_GRANTED_INT)
                add(Manifest.permission.ACCESS_FINE_LOCATION)
            if (Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PERMISSION_GRANTED_INT)
                add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (needed.isEmpty()) launchService() else requestPermissions(needed.toTypedArray(), REQ_PERMS)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_PERMS) launchService() // 没给定位也能投，只是车速显示 --
    }

    private fun launchService() {
        DashService.start(this, pkgInput.text.toString().trim(), keepScreen.isChecked)
    }

    private fun copyLog() {
        val cm = getSystemService(ClipboardManager::class.java)
        cm.setPrimaryClip(ClipData.newPlainText("zeeho-bridge-log", LogBus.snapshot().joinToString("\n")))
        Toast.makeText(this, "日志已复制", Toast.LENGTH_SHORT).show()
    }

    private fun scrollToEnd() = logScroll.post { logScroll.fullScroll(View.FOCUS_DOWN) }

    private fun text(s: String, size: Float, bold: Boolean = false, alpha: Int = 255) = TextView(this).apply {
        text = s; textSize = size
        setTextColor(Color.argb(alpha, 255, 255, 255))
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

    private fun button(label: String, onClick: () -> Unit) = Button(this).apply {
        text = label; setOnClickListener { onClick() }
    }

    private fun weightParams() = LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f)

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val REQ_PERMS = 1
        private const val PERMISSION_GRANTED_INT = android.content.pm.PackageManager.PERMISSION_GRANTED
    }
}
