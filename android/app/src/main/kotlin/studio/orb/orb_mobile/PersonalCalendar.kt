package studio.orb.orb_mobile

import android.Manifest.permission.READ_CALENDAR
import android.Manifest.permission.WRITE_CALENDAR
import android.content.ActivityNotFoundException
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import android.provider.CalendarContract.Attendees
import android.provider.CalendarContract.Calendars
import android.provider.CalendarContract.Events
import android.provider.CalendarContract.Instances
import androidx.lifecycle.Lifecycle
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.Duration
import java.util.TimeZone
import java.util.concurrent.Executors

/** Bound only to the foreground Flutter activity; no channel is installed on service engines. */
internal class PersonalCalendar(private val activity: MainActivity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "studio.orb/personal-calendar")
    private val resolver = activity.contentResolver
    private val permissions = arrayOf(READ_CALENDAR, WRITE_CALENDAR)
    private val prefs = activity.getSharedPreferences("personal-calendar", 0)
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(activity.packageManager.resolveContentProvider(CalendarContract.AUTHORITY, 0) != null)
                "permission" -> result.success(permission())
                "requestAccess" -> requestAccess(result)
                "calendars", "events", "get", "create", "update", "delete", "open" -> {
                    if (permission() != "granted") {
                        result.error("permission_denied", "请先允许 Orb 访问系统日历。", null)
                    } else if (call.method in setOf("create", "update", "delete", "open") && !foreground()) {
                        result.error("not_foreground", "请返回 Orb 操作日历。", null)
                    } else {
                        io.execute {
                            try {
                                val value = perform(call)
                                main.post {
                                    if (call.method == "open") openEvent(value as Map<*, *>, result)
                                    else result.success(value)
                                }
                            } catch (e: CalendarFailure) {
                                main.post { result.error(e.code, e.message, null) }
                            } catch (e: SecurityException) {
                                main.post { result.error("permission_denied", "系统日历拒绝了访问。", null) }
                            } catch (e: Exception) {
                                main.post { result.error("calendar_error", "系统日历未能完成操作。", null) }
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun foreground() = activity.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)

    private fun openEvent(event: Map<*, *>, result: MethodChannel.Result) {
        if (!foreground()) {
            result.error("not_foreground", "请返回 Orb 后打开日程。", null)
            return
        }
        val uri = ContentUris.withAppendedId(Events.CONTENT_URI, (event["id"] as String).toLong())
        val intent = Intent(Intent.ACTION_VIEW, uri)
            .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, event["startMs"] as Long)
            .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, event["endMs"] as Long)
        try {
            activity.startActivity(intent)
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            result.error("unavailable", "这台设备没有可打开事件详情的日历应用。", null)
        } catch (e: SecurityException) {
            result.error("permission_denied", "系统拒绝打开此日程。", null)
        }
    }

    private fun permission(): String {
        val pm = activity.packageManager
        if (permissions.all { activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) return "granted"
        if (permissions.any { pm.isPermissionRevokedByPolicy(it, activity.packageName) }) return "restricted"
        return if (prefs.getBoolean("requested", false)) "denied" else "undetermined"
    }

    private fun requestAccess(result: MethodChannel.Result) {
        val status = permission()
        when {
            status == "granted" || status == "restricted" -> result.success(status)
            !foreground() -> result.error("not_foreground", "请返回 Orb 允许访问日历。", null)
            pending != null -> result.error("busy", "正在等待日历授权。", null)
            else -> {
                pending = result
                activity.requestPermissions(permissions, PERMISSION_REQUEST)
            }
        }
    }

    fun onRequestPermissionsResult(requestCode: Int, grants: IntArray) {
        if (requestCode != PERMISSION_REQUEST || pending == null) return
        if (grants.isNotEmpty()) prefs.edit().putBoolean("requested", true).apply()
        pending?.success(permission())
        pending = null
    }

    fun close() {
        channel.setMethodCallHandler(null)
        pending?.error("cancelled", "日历授权已取消。", null)
        pending = null
        io.shutdown()
    }

    private fun calendars(id: Long? = null): List<Map<String, Any>> {
        val uri = if (id == null) Calendars.CONTENT_URI else ContentUris.withAppendedId(Calendars.CONTENT_URI, id)
        val selection = "${Calendars.DELETED}=0 AND ${Calendars.CALENDAR_ACCESS_LEVEL}>=?"
        val projection = arrayOf(Calendars._ID, Calendars.CALENDAR_DISPLAY_NAME, Calendars.CALENDAR_ACCESS_LEVEL)
        return resolver.query(uri, projection, selection, arrayOf(Calendars.CAL_ACCESS_READ.toString()), Calendars.CALENDAR_DISPLAY_NAME + " ASC")?.use { c ->
            buildList {
                while (c.moveToNext()) add(mapOf(
                    "id" to c.getLong(0).toString(), "title" to c.getString(1).orEmpty(),
                    "writable" to (c.getInt(2) >= Calendars.CAL_ACCESS_EDITOR),
                ))
            }
        } ?: throw CalendarFailure("unavailable", "系统日历不可用。")
    }

    private fun perform(call: MethodCall): Any {
        if (call.method == "calendars") return calendars()
        val calendarId = call.id("calendarId")
        val calendar = calendars(calendarId).firstOrNull() ?: throw CalendarFailure("not_found", "找不到所选日历。")
        if (call.method == "events") {
            val begin = call.number("fromMs")
            val end = call.number("toMs")
            val limit = call.argument<Number>("limit")?.toInt() ?: 50
            if (end <= begin || limit !in 1..50) invalid()
            val uri = Instances.CONTENT_URI.buildUpon().apply {
                ContentUris.appendId(this, begin)
                ContentUris.appendId(this, end)
            }.build()
            val projection = arrayOf(Instances.EVENT_ID, Instances.BEGIN, Instances.END) + commonColumns
            val selection = "${Events.CALENDAR_ID}=? AND ${Instances.BEGIN}<? AND ${Instances.END}>? AND ${Events.DELETED}=0"
            return resolver.query(uri, projection, selection,
                arrayOf(calendarId.toString(), end.toString(), begin.toString()),
                "${Instances.BEGIN} ASC, ${Instances.EVENT_ID} ASC")?.use { c ->
                buildList { while (size < limit && c.moveToNext()) add(event(c, c.getLong(0), c.getLong(1), c.getLong(2))) }
            } ?: throw CalendarFailure("unavailable", "系统日历不可用。")
        }
        if (call.method == "get" || call.method == "open") return get(calendarId, call.id("id"))
        if (calendar["writable"] != true) readOnly()
        if (call.method == "create") {
            val values = ContentValues().apply {
                put(Events.CALENDAR_ID, calendarId)
                put(Events.TITLE, call.title())
                put(Events.EVENT_LOCATION, call.argument<String>("location") ?: "")
                put(Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
                val start = call.number("startMs")
                val end = call.number("endMs")
                if (end <= start) invalid()
                put(Events.DTSTART, start)
                put(Events.DTEND, end)
            }
            val uri = resolver.insert(Events.CONTENT_URI, values)
                ?: throw CalendarFailure("calendar_error", "事件未保存。")
            return get(calendarId, ContentUris.parseId(uri))
        }
        val id = call.id("id")
        val current = get(calendarId, id)
        if (current["editable"] != true) readOnly()
        val selection = "${Events._ID}=? AND ${Events.CALENDAR_ID}=? AND ${Events.DELETED}=0"
        val selectionArgs = arrayOf(id.toString(), calendarId.toString())
        if (call.method == "delete") {
            if (resolver.delete(Events.CONTENT_URI, selection, selectionArgs) != 1) missing()
            return mapOf("id" to id.toString(), "calendarId" to calendarId.toString(), "deleted" to true)
        }
        val values = ContentValues()
        if (call.hasArgument("title")) values.put(Events.TITLE, call.title())
        if (call.hasArgument("location")) values.put(Events.EVENT_LOCATION, call.argument<String>("location") ?: "")
        if (call.hasArgument("startMs") || call.hasArgument("endMs")) {
            val start = call.argument<Number>("startMs")?.toLong() ?: current["startMs"] as Long
            val end = call.argument<Number>("endMs")?.toLong() ?: current["endMs"] as Long
            if (end <= start) invalid()
            values.put(Events.DTSTART, start)
            values.put(Events.DTEND, end)
        }
        if (values.size() == 0) invalid()
        if (resolver.update(Events.CONTENT_URI, values, selection, selectionArgs) != 1) missing()
        return get(calendarId, id)
    }

    private fun get(calendarId: Long, id: Long): Map<String, Any> {
        val projection = arrayOf(Events._ID, Events.DTSTART, Events.DTEND, Events.DURATION) + commonColumns
        val selection = "${Events._ID}=? AND ${Events.CALENDAR_ID}=? AND ${Events.DELETED}=0"
        return resolver.query(Events.CONTENT_URI, projection, selection,
            arrayOf(id.toString(), calendarId.toString()), null)?.use { c ->
            if (!c.moveToFirst() || c.getLong(c.getColumnIndexOrThrow(Events.CALENDAR_ID)) != calendarId) missing()
            val start = c.getLong(1)
            val duration = c.getString(3)
            val end = if (!c.isNull(2)) c.getLong(2) else start + durationMillis(duration)
            event(c, id, start, end)
        } ?: missing()
    }

    private fun durationMillis(duration: String?): Long {
        if (duration.isNullOrEmpty()) return 0
        val weeks = Regex("P(\\d+)W").matchEntire(duration)
        return if (weeks != null) Duration.ofDays(weeks.groupValues[1].toLong() * 7).toMillis()
            else Duration.parse(duration).toMillis()
    }

    private fun event(c: Cursor, id: Long, start: Long, end: Long): Map<String, Any> {
        fun text(column: String) = c.getString(c.getColumnIndexOrThrow(column)).orEmpty()
        val allDay = text(Events.ALL_DAY) == "1"
        val organizer = text(Events.ORGANIZER)
        val owner = text(Calendars.OWNER_ACCOUNT)
        val recurring = listOf(Events.RRULE, Events.RDATE, Events.ORIGINAL_ID, Events.ORIGINAL_SYNC_ID,
            Events.ORIGINAL_INSTANCE_TIME).any { text(it).isNotEmpty() }
        val organizedByUser = organizer.isEmpty() || organizer.equals(owner, ignoreCase = true) || text(Events.IS_ORGANIZER) == "1"
        val editable = !allDay && !recurring &&
            text(Calendars.CALENDAR_ACCESS_LEVEL).toInt() >= Calendars.CAL_ACCESS_EDITOR &&
            organizedByUser && !hasOtherAttendees(id, owner, organizer)
        return mapOf(
            "id" to id.toString(), "calendarId" to text(Events.CALENDAR_ID),
            "title" to text(Events.TITLE), "startMs" to start, "endMs" to end,
            "allDay" to allDay, "location" to text(Events.EVENT_LOCATION), "editable" to editable,
        )
    }

    private fun hasOtherAttendees(id: Long, owner: String, organizer: String): Boolean {
        // Some providers mark hasAttendeeData even for a personal appointment.
        // Check actual rows and treat an unidentifiable participant as external.
        return resolver.query(Attendees.CONTENT_URI, arrayOf(Attendees.ATTENDEE_EMAIL),
            "${Attendees.EVENT_ID}=?", arrayOf(id.toString()), null)?.use { rows ->
            while (rows.moveToNext()) {
                val address = rows.getString(0)?.trim().orEmpty()
                if (address.isEmpty() ||
                    (!address.equals(owner.trim(), ignoreCase = true) &&
                        !address.equals(organizer.trim(), ignoreCase = true))) return@use true
            }
            false
        } ?: true
    }

    private fun MethodCall.id(name: String) = argument<String>(name)?.toLongOrNull()?.takeIf { it > 0 } ?: invalid()
    private fun MethodCall.number(name: String) = argument<Number>(name)?.toLong() ?: invalid()
    private fun MethodCall.title() = argument<String>("title")?.trim()?.takeIf { it.isNotEmpty() } ?: invalid()
    private fun invalid(): Nothing = throw CalendarFailure("invalid", "请检查日历编号、标题和开始结束时间。")
    private fun missing(): Nothing = throw CalendarFailure("not_found", "找不到所选日历中的事件。")
    private fun readOnly(): Nothing = throw CalendarFailure("read_only", "此日历或事件仅支持查看。")
    private class CalendarFailure(val code: String, message: String) : Exception(message)

    companion object {
        private const val PERMISSION_REQUEST = 40764
        private val commonColumns = arrayOf(Events.CALENDAR_ID, Events.TITLE, Events.EVENT_LOCATION, Events.ALL_DAY,
            Events.RRULE, Events.RDATE, Events.ORIGINAL_ID, Events.ORIGINAL_SYNC_ID, Events.ORIGINAL_INSTANCE_TIME,
            Events.ORGANIZER, Events.IS_ORGANIZER, Calendars.OWNER_ACCOUNT, Calendars.CALENDAR_ACCESS_LEVEL)
    }
}
