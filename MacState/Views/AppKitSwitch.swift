import SwiftUI
import AppKit

struct AppKitSwitch: NSViewRepresentable {
    let label: String
    let isOn: Bool
    let onChanged: (Bool) -> Void

    func makeNSView(context: Context) -> NSSwitch {
        let nsSwitch = NSSwitch()
        nsSwitch.target = context.coordinator
        nsSwitch.action = #selector(Coordinator.valueChanged(_:))
        nsSwitch.controlSize = .small
        nsSwitch.state = isOn ? .on : .off
        return nsSwitch
    }

    func updateNSView(_ nsSwitch: NSSwitch, context: Context) {
        context.coordinator.label = label
        context.coordinator.onChanged = onChanged
        let newState: NSControl.StateValue = isOn ? .on : .off
        if nsSwitch.state != newState {
            nsSwitch.state = newState
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(label: label, onChanged: onChanged)
    }

    final class Coordinator: NSObject {
        var label: String
        var onChanged: (Bool) -> Void
        init(label: String, onChanged: @escaping (Bool) -> Void) {
            self.label = label
            self.onChanged = onChanged
        }
        @objc func valueChanged(_ sender: NSSwitch) {
            onChanged(sender.state == .on)
        }
    }
}
