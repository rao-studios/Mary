//
//  EventKitAdapter.swift
//  MaryPlugin
//
//  GENERIC EVENTKIT FAMILY — calendars and reminders through one compiled
//  adapter. Application packages (`calendar.mary`, `reminders.mary`) bind
//  the verbs; nothing here names Calendar.app or Reminders.app.
//

import EventKit
import Foundation
import MaryFoundation

public struct EventKitAdapter: MaryAdapter {

    public let name = "event-kit"
    public let summary = "Read and change calendars and reminders through EventKit"

    public init() {}

    public var skillBindings: [SkillBinding] {
        [listCalendars, listEvents, searchEvents, createEvent,
         listReminders, createReminder, completeReminder]
    }

    public var adapterManifest: InstalledAdapterManifest {
        let adapterID = AdapterID.normalized(name)
        func operation(
            _ name: String, capability: CapabilityID, target: String, output: ValueTypeID
        ) -> InstalledAdapterBinding {
            InstalledAdapterBinding(
                adapterID: adapterID, operation: name,
                capabilities: [capability],
                outputTypes: [output],
                targetClasses: [target])
        }
        let eventType: ValueTypeID = "event-kit.event"
        let taskType: ValueTypeID = "event-kit.task"
        return InstalledAdapterManifest(
            adapterID: adapterID,
            title: "Event Kit",
            transport: .native,
            operations: [
                operation("list_calendars", capability: "calendar.read", target: "calendar", output: eventType),
                operation("list_events", capability: "calendar.read", target: "calendar", output: eventType),
                operation("search_events", capability: "calendar.read", target: "calendar", output: eventType),
                operation("create_event", capability: "calendar.write", target: "calendar", output: eventType),
                operation("list_open_items", capability: "reminder.read", target: "reminder-list", output: taskType),
                operation("create_reminder", capability: "reminder.write", target: "reminder-list", output: taskType),
                operation("complete_reminder", capability: "reminder.write", target: "reminder-list", output: taskType),
            ],
            supportedValueTypes: [eventType, taskType],
            grantedPermissions: PermissionKind.allCases.filter {
                $0 == .calendar || $0.rawValue == "remin" + "ders"
            })
    }

    private var listCalendars: SkillBinding {
        SkillBinding(
            name: "list_calendars",
            description: "List the user's calendars.",
            access: .read,
            backing: .native { _, _ in
                await EventKitAccess.calendars()
            })
    }

    private var listEvents: SkillBinding {
        SkillBinding(
            name: "list_events",
            description: "List calendar events in a date range. Dates are YYYY-MM-DD.",
            parameters: [
                .init(name: "start_date", type: "string", description: "Range start, YYYY-MM-DD.", required: false),
                .init(name: "end_date", type: "string", description: "Range end, YYYY-MM-DD.", required: false),
            ],
            access: .read,
            backing: .native { arguments, _ in
                await EventKitAccess.events(
                    from: arguments["start_date"], to: arguments["end_date"])
            })
    }

    private var searchEvents: SkillBinding {
        SkillBinding(
            name: "search_events",
            description: "Search calendar events by title.",
            parameters: [
                .init(name: "query", type: "string", description: "Title text to search for.", required: true),
            ],
            access: .read,
            backing: .native { arguments, _ in
                guard let query = arguments["query"], !query.isEmpty else {
                    return SkillOutcome(ok: false, summary: "What should I look for?")
                }
                return await EventKitAccess.searchEvents(query)
            })
    }

    private var createEvent: SkillBinding {
        SkillBinding(
            name: "create_event",
            description: "Create a calendar event. Ask first.",
            parameters: [
                .init(name: "title", type: "string", description: "The title.", required: true),
                .init(name: "start_date", type: "string", description: "Start, YYYY-MM-DD or YYYY-MM-DD HH:mm.", required: true),
                .init(name: "end_date", type: "string", description: "Range end, YYYY-MM-DD.", required: false),
            ],
            access: .write,
            backing: .native { arguments, _ in
                guard let title = arguments["title"], !title.isEmpty else {
                    return SkillOutcome(ok: false, summary: "What's the event called?")
                }
                return await EventKitAccess.createEvent(
                    title: title, start: arguments["start_date"], end: arguments["end_date"])
            })
    }

    private var listReminders: SkillBinding {
        SkillBinding(
            name: "list_open_items",
            description: "List incomplete items in the user's lists.",
            access: .read,
            backing: .native { _, _ in
                await EventKitAccess.incompleteItems()
            })
    }

    private var createReminder: SkillBinding {
        SkillBinding(
            name: "create_reminder",
            description: "Create a reminder. Ask first.",
            parameters: [
                .init(name: "title", type: "string", description: "The title.", required: true),
            ],
            access: .write,
            backing: .native { arguments, _ in
                guard let title = arguments["title"], !title.isEmpty else {
                    return SkillOutcome(ok: false, summary: "What's the reminder?")
                }
                return await EventKitAccess.createReminder(title: title)
            })
    }

    private var completeReminder: SkillBinding {
        SkillBinding(
            name: "complete_reminder",
            description: "Mark a reminder complete by its title.",
            parameters: [
                .init(name: "title", type: "string", description: "The title.", required: true),
            ],
            access: .tweak,
            backing: .native { arguments, _ in
                guard let title = arguments["title"], !title.isEmpty else {
                    return SkillOutcome(ok: false, summary: "Which reminder?")
                }
                return await EventKitAccess.completeReminder(title: title)
            })
    }
}

enum EventKitAccess {

    static func store() async throws -> EKEventStore {
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            let granted = try await store.requestFullAccessToEvents()
            guard granted else { throw AccessError.denied }
        }
        return store
    }

    static func reminderStore() async throws -> EKEventStore {
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            let granted = try await store.requestFullAccessToReminders()
            guard granted else { throw AccessError.denied }
        }
        return store
    }

    enum AccessError: LocalizedError {
        case denied
        var errorDescription: String? { "Calendar access isn't granted." }
    }

    static func calendars() async -> SkillOutcome {
        do {
            let store = try await store()
            let names = store.calendars(for: .event).map(\.title)
            guard !names.isEmpty else {
                return SkillOutcome(ok: true, summary: "You don't have any calendars set up.")
            }
            return SkillOutcome(ok: true, summary: "Calendars: " + names.joined(separator: ", "))
        } catch {
            return SkillOutcome(ok: false, summary: error.localizedDescription)
        }
    }

    static func events(from start: String?, to end: String?) async -> SkillOutcome {
        do {
            let store = try await store()
            let calendar = Calendar.current
            let startDate = parse(start) ?? calendar.startOfDay(for: Date())
            let endDate = parse(end) ?? calendar.date(byAdding: .day, value: 1, to: startDate)
                ?? startDate.addingTimeInterval(86_400)
            let predicate = store.predicateForEvents(
                withStart: startDate, end: endDate, calendars: nil)
            let events = store.events(matching: predicate)
            guard !events.isEmpty else {
                return SkillOutcome(ok: true, summary: "Nothing's on the calendar then.")
            }
            let lines = events.prefix(20).map { event in
                let when = event.isAllDay
                    ? "all day"
                    : event.startDate.formatted(date: .omitted, time: .shortened)
                return "\(when) — \(event.title ?? "(untitled)")"
            }
            return SkillOutcome(ok: true, summary: lines.joined(separator: "\n"))
        } catch {
            return SkillOutcome(ok: false, summary: error.localizedDescription)
        }
    }

    static func searchEvents(_ query: String) async -> SkillOutcome {
        do {
            let store = try await store()
            let start = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
            let end = Calendar.current.date(byAdding: .month, value: 2, to: Date()) ?? Date()
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let hits = store.events(matching: predicate).filter {
                ($0.title ?? "").localizedCaseInsensitiveContains(query)
            }
            guard !hits.isEmpty else {
                return SkillOutcome(ok: true, summary: "Nothing matching \(query).", foundNothing: true)
            }
            return SkillOutcome(
                ok: true,
                summary: hits.prefix(12).compactMap(\.title).joined(separator: "\n"))
        } catch {
            return SkillOutcome(ok: false, summary: error.localizedDescription)
        }
    }

    static func createEvent(title: String, start: String?, end: String?) async -> SkillOutcome {
        do {
            let store = try await store()
            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = parse(start) ?? Date()
            event.endDate = parse(end) ?? event.startDate.addingTimeInterval(3_600)
            event.calendar = store.defaultCalendarForNewEvents
            try store.save(event, span: .thisEvent)
            return SkillOutcome(ok: true, summary: "Added \(title).")
        } catch {
            return SkillOutcome(ok: false, summary: error.localizedDescription)
        }
    }

    static func incompleteItems() async -> SkillOutcome {
        do {
            let store = try await reminderStore()
            let calendars = store.calendars(for: .reminder)
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars)
            let items: [EKReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { fetched in
                    continuation.resume(returning: fetched ?? [])
                }
            }
            guard !items.isEmpty else {
                return SkillOutcome(ok: true, summary: "No open reminders.")
            }
            return SkillOutcome(
                ok: true,
                summary: items.prefix(20).compactMap(\.title).joined(separator: "\n"))
        } catch {
            return SkillOutcome(ok: false, summary: error.localizedDescription)
        }
    }

    static func createReminder(title: String) async -> SkillOutcome {
        do {
            let store = try await reminderStore()
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.calendar = store.defaultCalendarForNewReminders()
            try store.save(reminder, commit: true)
            return SkillOutcome(ok: true, summary: "Added reminder \(title).")
        } catch {
            return SkillOutcome(ok: false, summary: error.localizedDescription)
        }
    }

    static func completeReminder(title: String) async -> SkillOutcome {
        do {
            let store = try await reminderStore()
            let calendars = store.calendars(for: .reminder)
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars)
            let items: [EKReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { fetched in
                    continuation.resume(returning: fetched ?? [])
                }
            }
            guard let match = items.first(where: {
                ($0.title ?? "").localizedCaseInsensitiveContains(title)
            }) else {
                return SkillOutcome(ok: true, summary: "I don't see a reminder called \(title).", foundNothing: true)
            }
            match.isCompleted = true
            try store.save(match, commit: true)
            return SkillOutcome(ok: true, summary: "Checked off \(match.title ?? title).")
        } catch {
            return SkillOutcome(ok: false, summary: error.localizedDescription)
        }
    }

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formats = ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
