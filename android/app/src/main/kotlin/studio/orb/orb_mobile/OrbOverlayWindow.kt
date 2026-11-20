package studio.orb.orb_mobile

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.*
import android.graphics.drawable.GradientDrawable
import android.hardware.input.InputManager
import android.os.*
import android.view.*
import android.widget.*
import kotlin.math.*

internal class OrbOverlayWindow(
    private val context: Context,
    private val prefs: OrbOverlaySettings,
    private val action: (String) -> Unit,
) {
    private val wm = context.getSystemService(WindowManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private var ball: Ball? = null
    private var position: WindowManager.LayoutParams? = null
    private var panel: LinearLayout? = null
    private var statusLabel: TextView? = null
    private var responseLabel: TextView? = null
    private var phase = "idle"
    private var lastAnswer = ""
    private var lastError = ""
    private var pressedHold = false
    private var dragged = false
    private var wasDouble = false
    private var lastTap = 0L
    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0
    private var dock: Dock? = null
    private enum class Dock { LEFT, RIGHT }
    private val single = Runnable {
        lastTap = 0
        action(prefs.tap)
    }
    private val hold = Runnable {
        if (!dragged && prefs.hold != "none") {
            handler.removeCallbacks(single)
            lastTap = 0
            pressedHold = true
            ball?.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            action(prefs.hold)
        }
    }

    private fun dp(value: Float) = (value * context.resources.displayMetrics.density).roundToInt()

    private fun dp(value: Int) = dp(value.toFloat())

    private fun dimensions(p: WindowManager.LayoutParams, side: Dock?) {
        dock = side
        val diameter = prefs.size
        p.width = dp(max(48f, if (side == null) diameter else diameter * .56f))
        p.height = dp(max(48f, if (side == null) diameter else diameter * .76f))
    }

    private fun area(): Rect {
        if (Build.VERSION.SDK_INT >= 30) {
            val m = wm.currentWindowMetrics
            val i =
                m.windowInsets.getInsetsIgnoringVisibility(
                    WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout()
                )
            return Rect(
                0,
                0,
                m.bounds.width() - i.left - i.right,
                m.bounds.height() - i.top - i.bottom,
            )
        }
        val p = android.graphics.Point()
        @Suppress("DEPRECATION") wm.defaultDisplay.getSize(p)
        return Rect(0, 0, p.x, p.y)
    }

    private fun windowParams(w: Int, h: Int, title: String): WindowManager.LayoutParams {
        @Suppress("DEPRECATION")
        val type =
            if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else WindowManager.LayoutParams.TYPE_PHONE
        return WindowManager.LayoutParams(
                w,
                h,
                type,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT,
            )
            .apply {
                gravity = Gravity.TOP or Gravity.LEFT
                setTitle(title)
            }
    }

    fun show() {
        val bounds = area()
        val params = position ?: windowParams(0, 0, "Orb voice shortcut")
        val side = if (!prefs.snap) null else if (prefs.xFraction < .5f) Dock.LEFT else Dock.RIGHT
        dimensions(params, side)
        val maxX = (bounds.width() - params.width).coerceAtLeast(0)
        params.x = when (side) {
            Dock.LEFT -> 0
            Dock.RIGHT -> maxX
            null -> (prefs.xFraction * maxX).roundToInt()
        }
        params.y = (prefs.yFraction * (bounds.height() - params.height).coerceAtLeast(0)).roundToInt()
        params.alpha =
            if (Build.VERSION.SDK_INT >= 31)
                min(
                    prefs.opacity,
                    context
                        .getSystemService(InputManager::class.java)
                        .maximumObscuringOpacityForTouch,
                )
            else prefs.opacity
        position = params
        val existing = ball
        if (existing == null) {
            val view = Ball(context)
            view.contentDescription = "Orb 悬浮球"
            view.isClickable = true
            view.setOnClickListener { action(prefs.tap) }
            view.setOnLongClickListener {
                if (prefs.hold != "none") action(prefs.hold)
                true
            }
            view.setOnTouchListener { _, event -> handleTouch(event) }
            wm.addView(view, params)
            ball = view
        } else {
            wm.updateViewLayout(existing, params)
            existing.invalidate()
        }
        positionPanel()
    }

    fun hide() {
        handler.removeCallbacks(single)
        handler.removeCallbacks(hold)
        lastTap = 0
        pressedHold = false
        closePanel()
        ball?.let { if (it.isAttachedToWindow) wm.removeViewImmediate(it) }
        ball = null
        position = null
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun handleTouch(e: MotionEvent): Boolean {
        val p = position ?: return false
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val now = SystemClock.uptimeMillis()
                wasDouble =
                    lastTap != 0L && now - lastTap <= ViewConfiguration.getDoubleTapTimeout()
                handler.removeCallbacks(single)
                downX = e.rawX
                downY = e.rawY
                startX = p.x
                startY = p.y
                pressedHold = false
                dragged = false
                action("interruptIfSpeaking")
                handler.postDelayed(hold, ViewConfiguration.getLongPressTimeout().toLong())
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = e.rawX - downX
                val dy = e.rawY - downY
                if (!pressedHold && (dragged || hypot(dx, dy) > slop)) {
                    if (!dragged && dock != null) {
                        val oldWidth = p.width
                        val oldHeight = p.height
                        val fromRight = dock == Dock.RIGHT
                        dimensions(p, null)
                        if (fromRight) startX += oldWidth - p.width
                        startY += (oldHeight - p.height) / 2
                        ball?.invalidate()
                    }
                    dragged = true
                    lastTap = 0
                    handler.removeCallbacks(hold)
                    moveTo(p, dx, dy)
                    ball?.let { wm.updateViewLayout(it, p) }
                    positionPanel()
                }
            }
            MotionEvent.ACTION_CANCEL -> {
                handler.removeCallbacks(hold)
                if (pressedHold) action("cancel")
                if (dragged) settle(p)
                pressedHold = false
                lastTap = 0
            }
            MotionEvent.ACTION_UP -> {
                handler.removeCallbacks(hold)
                when {
                    pressedHold -> {
                        pressedHold = false
                        action("release")
                    }
                    dragged -> {
                        moveTo(p, e.rawX - downX, e.rawY - downY)
                        settle(p)
                    }
                    wasDouble -> {
                        lastTap = 0
                        action(prefs.doubleTap)
                    }
                    else -> {
                        lastTap = SystemClock.uptimeMillis()
                        handler.postDelayed(
                            single,
                            ViewConfiguration.getDoubleTapTimeout().toLong(),
                        )
                    }
                }
            }
        }
        return true
    }

    private fun moveTo(p: WindowManager.LayoutParams, dx: Float, dy: Float) {
        val screen = area()
        p.x = (startX + dx.roundToInt()).coerceIn(0, (screen.width() - p.width).coerceAtLeast(0))
        p.y = (startY + dy.roundToInt()).coerceIn(0, (screen.height() - p.height).coerceAtLeast(0))
    }

    private fun settle(p: WindowManager.LayoutParams) {
        val screen = area()
        val centerY = p.y + p.height / 2
        val side = if (!prefs.snap) null
            else if (p.x + p.width / 2 < screen.width() / 2) Dock.LEFT else Dock.RIGHT
        dimensions(p, side)
        val maxX = (screen.width() - p.width).coerceAtLeast(0)
        val maxY = (screen.height() - p.height).coerceAtLeast(0)
        p.x = when (side) {
            Dock.LEFT -> 0
            Dock.RIGHT -> maxX
            null -> p.x.coerceIn(0, maxX)
        }
        p.y = (centerY - p.height / 2).coerceIn(0, maxY)
        prefs.savePosition(p.x.toFloat() / maxX.coerceAtLeast(1), p.y.toFloat() / maxY.coerceAtLeast(1))
        ball?.let {
            wm.updateViewLayout(it, p)
            it.invalidate()
        }
        positionPanel()
    }

    fun togglePanel(): Boolean {
        if (panel == null) showPanel() else closePanel()
        return panel != null
    }

    private fun closePanel() {
        panel?.let { if (it.isAttachedToWindow) wm.removeViewImmediate(it) }
        panel = null
        statusLabel = null
        responseLabel = null
    }

    private fun label(size: Float, color: Int) =
        TextView(context).apply {
            textSize = size
            setTextColor(color)
            includeFontPadding = false
        }

    private fun button(text: String, description: String, command: () -> Unit) =
        label(14f, Color.WHITE).apply {
            this.text = text
            contentDescription = description
            gravity = Gravity.CENTER
            isFocusable = true
            setPadding(dp(8), 0, dp(8), 0)
            setOnClickListener { command() }
        }

    fun showPanel() {
        if (ball == null || panel != null) return
        val back =
            GradientDrawable().apply {
                setColor(0xff20211f.toInt())
                cornerRadius = dp(19).toFloat()
                setStroke(dp(1), 0xff424242.toInt())
            }
        val card =
            LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                background = back
                setPadding(dp(14), dp(4), dp(10), dp(4))
                contentDescription = "Orb 语音面板"
            }
        val header = LinearLayout(context).apply { gravity = Gravity.CENTER_VERTICAL }
        statusLabel =
            label(15f, Color.WHITE).apply {
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            }
        header.addView(statusLabel, LinearLayout.LayoutParams(0, dp(44), 1f))
        statusLabel?.gravity = Gravity.CENTER_VERTICAL
        header.addView(button("×", "收起面板", ::closePanel), dp(44), dp(44))
        card.addView(header)
        responseLabel =
            label(15f, 0xffdddddd.toInt()).apply {
                setLineSpacing(dp(3).toFloat(), 1f)
                setPadding(0, dp(4), dp(4), dp(6))
            }
        val body =
            object : ScrollView(context) {
                override fun onMeasure(w: Int, h: Int) {
                    super.onMeasure(
                        w,
                        MeasureSpec.makeMeasureSpec(
                            min(dp(180), area().height() / 3),
                            MeasureSpec.AT_MOST,
                        ),
                    )
                }
            }
        body.addView(responseLabel)
        card.addView(body, LinearLayout.LayoutParams(-1, -2))
        val actions = LinearLayout(context).apply { gravity = Gravity.END }
        actions.addView(button("停止", "停止语音") { action("stop") }, -2, dp(44))
        actions.addView(button("打开 Orb", "打开 Orb") { action("open") }, -2, dp(44))
        card.addView(actions)
        val p =
            windowParams(
                min(dp(288), (area().width() - dp(16)).coerceAtLeast(dp(120))),
                -2,
                "Orb voice panel",
            )
        panel = card
        render()
        positionPanel(p, add = true)
        card.addOnLayoutChangeListener { _, _, _, _, b, _, _, _, old ->
            if (b != old && panel === card) card.post { if (panel === card) positionPanel() }
        }
    }

    private fun positionPanel(params: WindowManager.LayoutParams? = null, add: Boolean = false) {
        val p = position ?: return
        val card = panel ?: return
        val panelPos = params ?: card.layoutParams as? WindowManager.LayoutParams ?: return
        val screen = area()
        panelPos.x =
            (p.x + p.width / 2 - panelPos.width / 2).coerceIn(
                dp(8),
                (screen.width() - panelPos.width - dp(8)).coerceAtLeast(dp(8)),
            )
        val height = card.height.takeIf { it > 0 } ?: dp(125)
        val below = p.y + p.height + dp(6)
        panelPos.y =
            (if (below + height <= screen.height()) below else p.y - height - dp(6)).coerceAtLeast(
                dp(4)
            )
        if (add) wm.addView(card, panelPos)
        else if (card.isAttachedToWindow) wm.updateViewLayout(card, panelPos)
    }

    fun status(next: String, answer: String, error: String) {
        phase = next
        lastAnswer = answer
        lastError = error
        ball?.invalidate()
        render()
    }

    private fun render() {
        statusLabel?.text =
            when (phase) {
                "starting" -> "正在准备语音"
                "listening" -> "正在听 · 松开发送"
                "transcribing" -> "正在转写"
                "thinking" -> "正在思考"
                "speaking" -> "正在朗读"
                "error" -> "未能完成"
                else -> "Orb"
            }
        responseLabel?.text =
            when {
                lastError.isNotBlank() && lastAnswer.isNotBlank() -> "$lastError\n\n$lastAnswer"
                lastError.isNotBlank() -> lastError
                lastAnswer.isNotBlank() -> lastAnswer
                phase == "listening" -> "请说…"
                else -> "长按悬浮球说话"
            }
    }

    private inner class Ball(context: Context) : View(context) {
        private val ink = Paint(Paint.ANTI_ALIAS_FLAG)
        private val outline = Path()
        private val parallels = Path().also { filled ->
            val curves = Path()
            for (y in -25..15 step 10) {
                curves.moveTo(-44.5f, y.toFloat())
                curves.quadTo(0f, y + 21f, 44.5f, y.toFloat())
            }
            val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = 2.8f
            }
            stroke.getFillPath(curves, filled)
            // A filled intersection keeps the disc edge antialiased on Android.
            val disc = Path().apply { addCircle(0f, 0f, 32f, Path.Direction.CW) }
            filled.op(disc, Path.Op.INTERSECT)
        }

        override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
            super.onSizeChanged(w, h, oldw, oldh)
            // Reserve only this shortcut so an inward drag can leave either edge.
            if (Build.VERSION.SDK_INT >= 29) systemGestureExclusionRects = listOf(Rect(0, 0, w, h))
        }

        override fun onDraw(canvas: Canvas) {
            val diameter = dp(prefs.size).toFloat()
            val cy = height / 2f
            val edge = dock
            val markCenter: Float
            outline.reset()
            if (edge == null) {
                markCenter = width / 2f
                outline.addCircle(markCenter, cy, (diameter - dp(1)) / 2f, Path.Direction.CW)
            } else {
                val depth = diameter * .56f
                val radius = diameter * .38f
                val left = edge == Dock.LEFT
                val cap = if (left) depth - radius else width - depth + radius
                val flat = if (left) -dp(2).toFloat() else width + dp(2).toFloat()
                outline.moveTo(flat, cy - radius)
                outline.lineTo(cap, cy - radius)
                outline.arcTo(cap - radius, cy - radius, cap + radius, cy + radius,
                    -90f, if (left) 180f else -180f, false)
                outline.lineTo(flat, cy + radius)
                outline.close()
                markCenter = if (left) depth / 2f else width - depth / 2f
            }
            ink.style = Paint.Style.FILL
            ink.color = 0xff171717.toInt()
            canvas.drawPath(outline, ink)
            ink.style = Paint.Style.STROKE
            ink.strokeWidth = dp(1).toFloat()
            ink.color =
                if (phase in listOf("listening", "speaking")) Color.WHITE else 0xff686868.toInt()
            canvas.drawPath(outline, ink)
            val markScale = diameter * (if (edge == null) .53f else .45f) / 64f
            val save = canvas.save()
            canvas.translate(markCenter, cy)
            canvas.scale(markScale, markScale)
            ink.style = Paint.Style.FILL
            ink.color = 0xfff7f7f7.toInt()
            canvas.drawCircle(0f, 0f, 32f, ink)
            canvas.rotate(-26f)
            ink.color = Color.BLACK
            canvas.drawPath(parallels, ink)
            canvas.restoreToCount(save)
        }
    }
}
