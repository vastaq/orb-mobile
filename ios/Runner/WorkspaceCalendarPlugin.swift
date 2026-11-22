import EventKit
import Flutter
import UIKit

final class WorkspaceCalendarPlugin: NSObject, FlutterPlugin {
  private let store = EKEventStore()
  private weak var viewer: UINavigationController?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "studio.orb/personal-calendar", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(WorkspaceCalendarPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available": result(true)
    case "permission": result(permission())
    case "requestAccess": requestAccess(result)
    case "calendars", "events", "get", "open", "create", "update", "delete":
      do {
        guard permission() == "granted" else {
          throw CalendarFailure("permission_denied", "请先允许 Orb 访问日历。")
        }
        result(try perform(call.method, call.arguments as? [String: Any] ?? [:]))
      } catch let failure as CalendarFailure {
        result(FlutterError(code: failure.code, message: failure.message, details: nil))
      } catch {
        result(FlutterError(code: "calendar_error", message: error.localizedDescription, details: nil))
      }
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func permission() -> String {
    let status = EKEventStore.authorizationStatus(for: .event)
    if #available(iOS 17.0, *) {
      if status == .fullAccess { return "granted" }
      // A previous write-only grant can still be upgraded by the user.
      if status == .writeOnly { return "undetermined" }
    } else if status == .authorized {
      return "granted"
    }
    if status == .notDetermined { return "undetermined" }
    if status == .restricted { return "restricted" }
    return "denied"
  }

  private func requestAccess(_ result: @escaping FlutterResult) {
    let prior = permission()
    guard prior == "undetermined" else { result(prior); return }
    guard UIApplication.shared.applicationState == .active else {
      result(FlutterError(code: "foreground_required", message: "请在打开 Orb 后授权。", details: nil))
      return
    }
    let completed: (Bool, Error?) -> Void = { _, error in
      DispatchQueue.main.async {
        let state = self.permission()
        if let error, state == "undetermined" {
          result(FlutterError(code: "calendar_error", message: error.localizedDescription, details: nil))
        } else {
          result(state)
        }
      }
    }
    if #available(iOS 17.0, *) {
      store.requestFullAccessToEvents(completion: completed)
    } else {
      store.requestAccess(to: .event, completion: completed)
    }
  }

  private func perform(_ method: String, _ args: [String: Any]) throws -> Any {
    if method == "calendars" {
      return store.calendars(for: .event).map { calendar in
        ["id": calendar.calendarIdentifier, "title": calendar.title ?? "", "writable": calendar.allowsContentModifications] as [String: Any]
      }
    }
    guard let calendarID = args["calendarId"] as? String, !calendarID.isEmpty else {
      throw CalendarFailure("invalid_arguments", "缺少日历标识。")
    }
    guard let calendar = store.calendar(withIdentifier: calendarID), calendar.allowedEntityTypes.contains(.event) else {
      throw CalendarFailure("not_found", "找不到该日历。")
    }

    if method == "events" {
      let from = try date("fromMs", args)
      let to = try date("toMs", args)
      guard to > from, let limit = args["limit"] as? Int, (1...50).contains(limit) else {
        throw CalendarFailure("invalid_arguments", "日期范围或数量无效。")
      }
      guard let last = Calendar(identifier: .gregorian).date(byAdding: .year, value: 4, to: from), to <= last else {
        throw CalendarFailure("invalid_arguments", "单次查询最多支持四年。")
      }
      let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
      return store.events(matching: predicate)
        .filter { $0.startDate < to && $0.endDate > from }
        .sorted { $0.compareStartDate(with: $1) == .orderedAscending }
        .prefix(limit).map(record)
    }

    let event: EKEvent
    if method == "create" {
      guard calendar.allowsContentModifications else { throw readOnly() }
      event = EKEvent(eventStore: store)
      event.calendar = calendar
    } else {
      guard let id = args["id"] as? String, let existing = findEvent(id, in: calendar) else {
        throw CalendarFailure("not_found", "在所选日历中找不到该日程。")
      }
      event = existing
      if method == "get" { return record(event) }
      if method == "open" { return try openEvent(event) }
      guard editable(event) else { throw readOnly() }
      if method == "delete" {
        try store.remove(event, span: .thisEvent, commit: true)
        return ["id": id, "calendarId": calendarID, "deleted": true] as [String: Any]
      }
    }

    let start = method == "create" || args["startMs"] != nil ? try date("startMs", args) : event.startDate!
    let end = method == "create" || args["endMs"] != nil ? try date("endMs", args) : event.endDate!
    guard end > start else { throw CalendarFailure("invalid_arguments", "结束必须晚于开始。") }
    if method == "create" || args["title"] != nil {
      guard let title = args["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CalendarFailure("invalid_arguments", "日程标题不能为空。")
      }
      event.title = title
    }
    if let value = args["location"] {
      guard let location = value as? String else { throw CalendarFailure("invalid_arguments", "地点无效。") }
      event.location = location
    }
    event.startDate = start
    event.endDate = end
    try store.save(event, span: .thisEvent, commit: true)
    return record(event)
  }

  private func openEvent(_ event: EKEvent) throws -> Bool {
    guard viewer == nil, UIApplication.shared.applicationState == .active,
          let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
          let presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController,
          presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else {
      throw CalendarFailure("presentation_unavailable", "请返回 Orb 前台后再打开日程。")
    }
    let details = CalendarEventDetails(event: event)
    let navigation = UINavigationController(rootViewController: details)
    viewer = navigation
    presenter.present(navigation, animated: true)
    return true
  }

  private func date(_ key: String, _ args: [String: Any]) throws -> Date {
    guard let value = args[key] as? Int64 else { throw CalendarFailure("invalid_arguments", "缺少有效的时间。") }
    return Date(timeIntervalSince1970: Double(value) / 1000)
  }

  private func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }

  private func editable(_ event: EKEvent) -> Bool {
    event.calendar.allowsContentModifications && !event.isAllDay && !event.hasRecurrenceRules &&
      !event.isDetached && !event.hasAttendees && event.organizer == nil && event.status != .canceled
  }

  private func readOnly() -> CalendarFailure {
    CalendarFailure("read_only", "仅可修改可写日历中的普通单次日程。")
  }

  // EventKit resolves a recurring event identifier to its first occurrence.
  // Include the displayed occurrence's start so get returns that instance.
  private func identifier(_ event: EKEvent) -> String {
    let id = event.eventIdentifier ?? ""
    if event.hasRecurrenceRules || event.isDetached {
      return "occ:\(milliseconds(event.startDate)):\(id)"
    }
    return id
  }

  private func findEvent(_ id: String, in calendar: EKCalendar) -> EKEvent? {
    if id.hasPrefix("occ:") {
      let parts = id.split(separator: ":", maxSplits: 2)
      guard parts.count == 3, let time = Int64(parts[1]) else { return nil }
      let date = Date(timeIntervalSince1970: Double(time) / 1000)
      let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-1), end: date.addingTimeInterval(1), calendars: [calendar])
      return store.events(matching: predicate).first { identifier($0) == id }
    }
    guard !id.isEmpty, let event = store.event(withIdentifier: id),
          event.calendar.calendarIdentifier == calendar.calendarIdentifier else { return nil }
    return event
  }

  private func record(_ event: EKEvent) -> [String: Any] {
    ["id": identifier(event), "calendarId": event.calendar.calendarIdentifier, "title": event.title ?? "",
     "startMs": milliseconds(event.startDate), "endMs": milliseconds(event.endDate),
     "allDay": event.isAllDay, "location": event.location ?? "", "editable": editable(event)]
  }
}

// EventKit's event viewer can still delete a saved event when editing is disabled.
// Keep this user-initiated receipt view read-only by displaying values from the matched event.
private final class CalendarEventDetails: UITableViewController {
  private let rows: [(String, String)]

  init(event: EKEvent) {
    let zone = event.timeZone ?? .current
    let format = DateFormatter()
    format.locale = .autoupdatingCurrent
    format.timeZone = zone
    format.dateStyle = .long
    format.timeStyle = event.isAllDay ? .none : .medium
    let location = event.location ?? ""
    var values = [
      ("标题", event.title ?? ""), ("开始", format.string(from: event.startDate)),
      (event.isAllDay ? "结束（不含当日）" : "结束", format.string(from: event.endDate)),
      ("时区", zone.identifier), ("地点", location.isEmpty ? "未填写" : location),
      ("日历", event.calendar.title ?? "")
    ]
    if let notes = event.notes, !notes.isEmpty { values.append(("备注", notes)) }
    rows = values
    super.init(style: .insetGrouped)
    title = "日程详情"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done, target: self, action: #selector(close))
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.allowsSelection = false
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    rows.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "field") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "field")
    let (label, value) = rows[indexPath.row]
    var content = cell.defaultContentConfiguration()
    content.text = label
    content.textProperties.font = .preferredFont(forTextStyle: .caption1)
    content.textProperties.color = .secondaryLabel
    content.secondaryText = value
    content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
    content.secondaryTextProperties.numberOfLines = 0
    cell.contentConfiguration = content
    cell.accessibilityLabel = label + "，" + value
    return cell
  }

  @objc private func close() { dismiss(animated: true) }
}

private struct CalendarFailure: Error {
  let code: String
  let message: String

  init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
}
