import AppKit
import SwiftUI

// MARK: - KeyEventHandler

final class KeyEventHandler {
    static let shared = KeyEventHandler()

    private var stack: [(id: String, box: HandlerBox)] = []
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event: event) ? nil : event
        }
    }

    func register(id: String, handler: @escaping (NSEvent) -> Bool) {
        if let existing = stack.first(where: { $0.id == id }) {
            existing.box.handler = handler
        } else {
            stack.append((id: id, box: HandlerBox(handler)))
        }
    }

    func unregister(id: String) {
        stack.removeAll { $0.id == id }
    }

    private func handle(event: NSEvent) -> Bool {
        for entry in stack.reversed() {
            if entry.box.handler(event) { return true }
        }
        return false
    }
}

final class HandlerBox {
    var handler: (NSEvent) -> Bool
    init(_ h: @escaping (NSEvent) -> Bool) { handler = h }
}

// MARK: - View modifier
//
// Uses a Coordinator (class instance) to safely manage registration lifetime.
// The Coordinator is created once per view identity and torn down with the view.
// updateNSView only updates the closure — it never re-registers after unregister.

struct KeyHandlerModifier: ViewModifier {
    let id: String
    let handler: (NSEvent) -> Bool

    func body(content: Content) -> some View {
        content.background(
            KeyHandlerUpdater(id: id, handler: handler)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}

struct KeyHandlerUpdater: NSViewRepresentable {
    let id: String
    let handler: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.register(id: id, handler: handler)
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(handler: handler)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.unregister()
    }

    // Coordinator owns the registration lifecycle
    final class Coordinator {
        private var registeredId: String?

        func register(id: String, handler: @escaping (NSEvent) -> Bool) {
            registeredId = id
            KeyEventHandler.shared.register(id: id, handler: handler)
        }

        func update(handler: @escaping (NSEvent) -> Bool) {
            // Only update the closure — never re-register after dismantleNSView
            guard let id = registeredId else { return }
            KeyEventHandler.shared.register(id: id, handler: handler)
        }

        func unregister() {
            guard let id = registeredId else { return }
            KeyEventHandler.shared.unregister(id: id)
            registeredId = nil  // prevent any further updates
        }
    }
}

extension View {
    func onWindowKeyPress(id: String, handler: @escaping (NSEvent) -> Bool) -> some View {
        modifier(KeyHandlerModifier(id: id, handler: handler))
    }
}
