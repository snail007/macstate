import AppKit
import SwiftUI
import Combine

private enum MetricSegmentKind: CaseIterable {
    case cpu
    case cpuTemp
    case memory
    case fan
    case network
    case battery
    case gpu
    case gpuTemp
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let metricsItem: NSStatusItem
    private let settingsItem: NSStatusItem

    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private let manager: MonitorManager

    private var cpuObserver: Any?
    private var cpuTempObserver: Any?
    private var memoryObserver: Any?
    private var fanObserver: Any?
    private var networkObserver: Any?
    private var batteryObserver: Any?
    private var gpuObserver: Any?
    private var gpuTempObserver: Any?

    private var hostingController: NSHostingController<PopoverView>?

    private let segmentSpacing: CGFloat = 4
    private var segmentVisibility: [MetricSegmentKind: Bool] = [:]

    private var pendingCpu: String = " --"
    private var pendingCpuTemp: String = " --"
    private var pendingMemory: String = " --"
    private var pendingFan: String = " --"
    private var pendingNetUpload: String = " --"
    private var pendingNetDownload: String = " --"
    private var pendingBattery: String = " --"
    private var pendingGpu: String = " --"
    private var pendingGpuTemp: String = " --"
    private var activeTip: NSPopover?
    private var tipClickMonitor: Any?
    private var pendingBatteryIcon: String = "bolt.fill"
    private var pendingBatteryPercent: Int = 0
    private var renderScheduled = false
    private var energyRefreshTimer: Timer?

    private var segmentRanges: [(MetricSegmentKind, ClosedRange<CGFloat>)] = []

    private let metricFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let networkFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private let iconConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)

    private var maxSegmentWidths: [MetricSegmentKind: CGFloat] = [:]

    init(manager: MonitorManager) {
        self.manager = manager

        settingsItem = NSStatusBar.system.statusItem(withLength: 18)
        metricsItem = NSStatusBar.system.statusItem(withLength: 10)

        super.init()

        setupPopover()
        setupSettingsItem()
        setupMetricsButton()
        setupInitialSegmentVisibility()
        observeDataChanges()
        observeToggleNotifications()
        observeLanguageChange()
        scheduleRender()
    }

    deinit {
        if let cpuObserver { NotificationCenter.default.removeObserver(cpuObserver) }
        if let cpuTempObserver { NotificationCenter.default.removeObserver(cpuTempObserver) }
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        if let fanObserver { NotificationCenter.default.removeObserver(fanObserver) }
        if let networkObserver { NotificationCenter.default.removeObserver(networkObserver) }
        if let batteryObserver { NotificationCenter.default.removeObserver(batteryObserver) }
        if let gpuObserver { NotificationCenter.default.removeObserver(gpuObserver) }
        if let gpuTempObserver { NotificationCenter.default.removeObserver(gpuTempObserver) }
    }

    // MARK: - Setup

    private func setupPopover() {
        popover.contentSize = NSSize(width: 280, height: 400)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            popover.contentViewController = nil
            hostingController = nil
        }
    }

    private func setupSettingsItem() {
        settingsItem.button?.target = self
        settingsItem.button?.action = #selector(settingsItemClicked(_:))
        let icon = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: L10n.shared.settings)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        settingsItem.button?.image = icon?.withSymbolConfiguration(config)
        settingsItem.length = 18
    }

    private func setupMetricsButton() {
        guard let button = metricsItem.button else { return }
        button.target = self
        button.action = #selector(metricsItemClicked(_:))
        button.imagePosition = .imageOnly
        button.title = ""
    }

    private func setupInitialSegmentVisibility() {
        segmentVisibility[.cpu] = CpuToggle.shared.enabled
        segmentVisibility[.cpuTemp] = CpuTempToggle.shared.enabled
        segmentVisibility[.memory] = MemoryToggle.shared.enabled
        segmentVisibility[.fan] = FanToggle.shared.enabled
        segmentVisibility[.network] = NetworkToggle.shared.enabled
        segmentVisibility[.battery] = BatteryService.hasBattery && BatteryToggle.shared.enabled
        segmentVisibility[.gpu] = GPUService.hasGPU && GpuToggle.shared.enabled
        segmentVisibility[.gpuTemp] = GPUService.hasGPU && GpuTempToggle.shared.enabled
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushRender()
        }
    }

    private func flushRender() {
        renderScheduled = false
        guard let button = metricsItem.button else { return }

        let barHeight = NSStatusBar.system.thickness
        let iconSize: CGFloat = 12
        let iconTextGap: CGFloat = 2

        let order: [MetricSegmentKind] = [.network, .memory, .cpu, .cpuTemp, .fan, .battery, .gpu, .gpuTemp]

        struct SegmentInfo {
            let kind: MetricSegmentKind
            let width: CGFloat
        }

        var segments: [SegmentInfo] = []
        var totalWidth: CGFloat = 0
        var ranges: [(MetricSegmentKind, ClosedRange<CGFloat>)] = []

        for kind in order {
            guard segmentVisibility[kind] == true else { continue }

            let iconName: String
            switch kind {
            case .cpu: iconName = "gauge.medium"
            case .cpuTemp: iconName = "thermometer.medium"
            case .memory: iconName = "memorychip"
            case .fan: iconName = "fan"
            case .network: iconName = "network"
            case .battery: iconName = self.pendingBatteryIcon
            case .gpu: iconName = "display"
            case .gpuTemp: iconName = "thermometer.sun.fill"
            }

            var actualIconW = iconSize
            if iconName == "_battery_custom_" {
                actualIconW = 22 + 3  // batteryBodyW + batteryCapW, must match drawing code
            } else if let iconImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                .withSymbolConfiguration(iconConfig) {
                let rawSize = iconImage.size
                if rawSize.width > rawSize.height && rawSize.height > 0 {
                    actualIconW = iconSize * rawSize.width / rawSize.height
                }
            }

            let width: CGFloat
            switch kind {
            case .network:
                let topStr = "↑\(pendingNetUpload)"
                let bottomStr = "↓\(pendingNetDownload)"
                let topW = (topStr as NSString).size(withAttributes: [.font: networkFont]).width
                let bottomW = (bottomStr as NSString).size(withAttributes: [.font: networkFont]).width
                let textW = max(topW, bottomW)
                width = actualIconW + iconTextGap + textW
            default:
                let text: String
                switch kind {
                case .cpu: text = pendingCpu
                case .cpuTemp: text = pendingCpuTemp
                case .memory: text = pendingMemory
                case .fan: text = pendingFan
                case .battery: text = pendingBattery
                case .gpu: text = pendingGpu
                case .gpuTemp: text = pendingGpuTemp
                default: text = ""
                }
                let textW = (text as NSString).size(withAttributes: [.font: metricFont]).width
                width = actualIconW + iconTextGap + textW
            }

            let stableWidth = ceil(max(width, maxSegmentWidths[kind] ?? 0))
            if stableWidth > (maxSegmentWidths[kind] ?? 0) {
                maxSegmentWidths[kind] = stableWidth
            }

            segments.append(SegmentInfo(kind: kind, width: stableWidth))
        }

        for (i, seg) in segments.enumerated() {
            let x = totalWidth
            totalWidth += seg.width
            if i < segments.count - 1 { totalWidth += segmentSpacing }
            ranges.append((seg.kind, x...(x + seg.width)))
        }

        totalWidth = max(10, ceil(totalWidth))
        segmentRanges = ranges

        let image = NSImage(size: NSSize(width: totalWidth, height: barHeight), flipped: false) { [self] drawRect in
            var x: CGFloat = 0

            for seg in segments {
                let iconName: String
                switch seg.kind {
                case .cpu: iconName = "cpu.fill"
                case .cpuTemp: iconName = "thermometer.medium"
                case .memory: iconName = "memorychip"
                case .fan: iconName = "fan"
                case .network: iconName = "network"
                case .battery: iconName = self.pendingBatteryIcon
                case .gpu: iconName = "display"
                case .gpuTemp: iconName = "thermometer.sun.fill"
                }

                var actualIconW = iconSize

                if iconName == "_battery_custom_" {
                    let batteryH: CGFloat = 11
                    let bodyW: CGFloat = 22
                    let capW: CGFloat = 3
                    let capH = batteryH * 0.5
                    let batteryW = bodyW + capW
                    let iconY = (barHeight - batteryH) / 2
                    let lineW: CGFloat = 1.0
                    let bodyRect = NSRect(x: x, y: iconY, width: bodyW, height: batteryH)

                    // Battery outline
                    let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 3.5, yRadius: 3.5)
                    bodyPath.lineWidth = lineW
                    NSColor.labelColor.setStroke()
                    bodyPath.stroke()

                    // Battery cap (positive terminal)
                    let capX = x + bodyW
                    let capY = iconY + (batteryH - capH) / 2
                    let capRect = NSRect(x: capX, y: capY, width: capW, height: capH)
                    let capPath = NSBezierPath(roundedRect: capRect, xRadius: 1.5, yRadius: 1.5)
                    NSColor.labelColor.setFill()
                    capPath.fill()

                    let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let depleteColor: NSColor = NSColor(white: 0.82, alpha: 1)
                    let textColor: NSColor = isDark ? NSColor(white: 0.45, alpha: 1) : .white

                    let pct = CGFloat(max(0, min(100, self.pendingBatteryPercent))) / 100.0
                    let inset: CGFloat = 0
                    let fillMaxW = bodyW - inset * 2
                    let fillW = fillMaxW * pct
                    let innerRect = NSRect(x: x + inset, y: iconY + inset, width: fillMaxW, height: batteryH - inset * 2)

                    // Depleted area (light gray, fills right up to the border)
                    let depletePath = NSBezierPath(roundedRect: innerRect, xRadius: 3, yRadius: 3)
                    depleteColor.setFill()
                    depletePath.fill()

                    // Charged area (labelColor, same as outline)
                    if fillW > 0 {
                        let fillRect = NSRect(x: x + inset, y: iconY + inset, width: fillW, height: batteryH - inset * 2)
                        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3)
                        NSColor.labelColor.setFill()
                        fillPath.fill()
                    }

                    // Percentage number in single contrasting color
                    let pctText = "\(self.pendingBatteryPercent)"
                    let pctFont = NSFont.monospacedDigitSystemFont(ofSize: round(batteryH * 0.80), weight: .bold)
                    let textSize = (pctText as NSString).size(withAttributes: [.font: pctFont])
                    let textOrigin = NSPoint(
                        x: x + (bodyW - textSize.width) / 2,
                        y: iconY + (batteryH - textSize.height) / 2
                    )
                    (pctText as NSString).draw(at: textOrigin, withAttributes: [.font: pctFont, .foregroundColor: textColor])

                    actualIconW = batteryW
                } else if let iconImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(self.iconConfig.applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))) {
                    let rawSize = iconImage.size
                    let drawW: CGFloat
                    let drawH: CGFloat
                    if rawSize.width > rawSize.height && rawSize.height > 0 {
                        drawH = iconSize
                        drawW = iconSize * rawSize.width / rawSize.height
                    } else {
                        drawW = iconSize
                        drawH = iconSize
                    }
                    let iconY = (barHeight - drawH) / 2
                    iconImage.draw(in: NSRect(x: x, y: iconY, width: drawW, height: drawH))
                    actualIconW = drawW
                }

                let textX = x + actualIconW + iconTextGap

                if seg.kind == .network {
                    let topStr = "↑\(self.pendingNetUpload)"
                    let bottomStr = "↓\(self.pendingNetDownload)"
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: self.networkFont,
                        .foregroundColor: NSColor.labelColor
                    ]
                    let lineHeight = (topStr as NSString).size(withAttributes: attrs).height
                    let totalTextHeight = lineHeight * 2
                    let startY = (barHeight - totalTextHeight) / 2
                    let bottomY = startY
                    let topY = startY + lineHeight

                    (topStr as NSString).draw(at: NSPoint(x: textX, y: topY), withAttributes: attrs)
                    (bottomStr as NSString).draw(at: NSPoint(x: textX, y: bottomY), withAttributes: attrs)
                } else {
                    let text: String
                    switch seg.kind {
                    case .cpu: text = self.pendingCpu
                    case .cpuTemp: text = self.pendingCpuTemp
                    case .memory: text = self.pendingMemory
                    case .fan: text = self.pendingFan
                    case .battery: text = self.pendingBattery
                    case .gpu: text = self.pendingGpu
                    case .gpuTemp: text = self.pendingGpuTemp
                    default: text = ""
                    }
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: self.metricFont,
                        .foregroundColor: NSColor.labelColor
                    ]
                    let textSize = (text as NSString).size(withAttributes: attrs)
                    let textY = (barHeight - textSize.height) / 2
                    (text as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)
                }

                x += seg.width + self.segmentSpacing
            }

            return true
        }

        image.isTemplate = false

        if metricsItem.length != totalWidth {
            metricsItem.length = totalWidth
        }
        button.image = image
    }

    // MARK: - Toggle Visibility

    private func observeToggleNotifications() {
        cpuObserver = NotificationCenter.default.addObserver(
            forName: CpuToggle.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let enabled = notification.userInfo?["enabled"] as? Bool else { return }
            self.setVisibility(enabled, for: .cpu)
        }

        cpuTempObserver = NotificationCenter.default.addObserver(
            forName: CpuTempToggle.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let enabled = notification.userInfo?["enabled"] as? Bool else { return }
            self.setVisibility(enabled, for: .cpuTemp)
        }

        memoryObserver = NotificationCenter.default.addObserver(
            forName: MemoryToggle.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let enabled = notification.userInfo?["enabled"] as? Bool else { return }
            self.setVisibility(enabled, for: .memory)
        }

        fanObserver = NotificationCenter.default.addObserver(
            forName: FanToggle.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let enabled = notification.userInfo?["enabled"] as? Bool else { return }
            self.setVisibility(enabled, for: .fan)
        }

        networkObserver = NotificationCenter.default.addObserver(
            forName: NetworkToggle.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let enabled = notification.userInfo?["enabled"] as? Bool else { return }
            self.setVisibility(enabled, for: .network)
        }

        batteryObserver = NotificationCenter.default.addObserver(
            forName: BatteryToggle.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let enabled = notification.userInfo?["enabled"] as? Bool else { return }
            self.setVisibility(BatteryService.hasBattery && enabled, for: .battery)
        }

        gpuObserver = NotificationCenter.default.addObserver(
            forName: GpuToggle.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let enabled = notification.userInfo?["enabled"] as? Bool else { return }
            self.setVisibility(GPUService.hasGPU && enabled, for: .gpu)
        }

        gpuTempObserver = NotificationCenter.default.addObserver(
            forName: GpuTempToggle.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let enabled = notification.userInfo?["enabled"] as? Bool else { return }
            self.setVisibility(GPUService.hasGPU && enabled, for: .gpuTemp)
        }
    }

    private func setVisibility(_ visible: Bool, for kind: MetricSegmentKind) {
        segmentVisibility[kind] = visible
        maxSegmentWidths[kind] = nil
        scheduleRender()
    }

    // MARK: - Observe Data Changes

    private func observeDataChanges() {
        manager.$cpuUsage
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.pendingCpu = String(format: " %.0f%%", value)
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$cpuTemp
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.pendingCpuTemp = value > 0 ? String(format: " %.0f\u{00B0}", value) : " --"
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$memoryUsage
            .removeDuplicates { $0.usedPercentage == $1.usedPercentage }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (mem: MemoryUsage) in
                guard let self else { return }
                self.pendingMemory = String(format: " %.0f%%", mem.usedPercentage)
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$fanSpeeds
            .removeDuplicates { lhs, rhs in
                guard lhs.count == rhs.count else { return false }
                return zip(lhs, rhs).allSatisfy { Int($0.0.current) == Int($0.1.current) }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (fans: [(current: Double, min: Double, max: Double)]) in
                guard let self else { return }
                self.pendingFan = fans.isEmpty ? " --" : String(format: " %.0f", fans.first?.current ?? 0)
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$networkSpeed
            .removeDuplicates { $0.upload == $1.upload && $0.download == $1.download }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (speed: NetworkSpeed) in
                guard let self else { return }
                self.pendingNetUpload = speed.uploadFormatted
                self.pendingNetDownload = speed.downloadFormatted
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$batteryInfo
            .removeDuplicates { lhs, rhs in
                lhs.percentage == rhs.percentage &&
                lhs.isCharging == rhs.isCharging &&
                lhs.isPluggedIn == rhs.isPluggedIn &&
                Int(lhs.adapterPowerWatts * 10) == Int(rhs.adapterPowerWatts * 10) &&
                Int(lhs.powerWatts * 10) == Int(rhs.powerWatts * 10)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (info: BatteryInfo) in
                guard let self else { return }
                self.pendingBatteryPercent = info.percentage
                if info.isCharging {
                    self.pendingBatteryIcon = "bolt.fill"
                } else if info.isPluggedIn {
                    self.pendingBatteryIcon = "powerplug.fill"
                } else {
                    self.pendingBatteryIcon = "_battery_custom_"
                }
                if info.isAvailable {
                    let w = info.adapterPowerWatts > 0 ? info.adapterPowerWatts : abs(info.powerWatts)
                    self.pendingBattery = w > 0.05 ? String(format: " %.1fW", w) : " --"
                } else {
                    self.pendingBattery = " --"
                }
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$gpuUsage
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.pendingGpu = value >= 0 ? String(format: " %.0f%%", value) : " --"
                self.scheduleRender()
            }
            .store(in: &cancellables)

        manager.$gpuTemp
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.pendingGpuTemp = value > 0 ? String(format: " %.0f\u{00B0}", value) : " --"
                self.scheduleRender()
            }
            .store(in: &cancellables)
    }

    // MARK: - Language Change

    private func observeLanguageChange() {
        L10n.shared.$language
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshPopover()
            }
            .store(in: &cancellables)
    }

    private func refreshPopover() {
        if popover.isShown {
            hostingController?.rootView = PopoverView(manager: manager)
        }
    }

    // MARK: - Click Handling

    @objc private func settingsItemClicked(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            let hc = NSHostingController(rootView: PopoverView(manager: manager))
            hostingController = hc
            popover.contentViewController = hc
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func metricsItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            showCpuUsageTooltip(button: sender)
            return
        }

        let pointInWindow = event.locationInWindow
        let pointInButton = sender.convert(pointInWindow, from: nil)

        for (kind, range) in segmentRanges {
            if range.contains(pointInButton.x) {
                showTooltip(for: kind, button: sender)
                return
            }
        }

        showCpuUsageTooltip(button: sender)
    }

    private func segmentRect(for kind: MetricSegmentKind, in button: NSStatusBarButton) -> NSRect {
        for (k, range) in segmentRanges {
            if k == kind {
                return NSRect(x: range.lowerBound, y: 0, width: range.upperBound - range.lowerBound, height: button.bounds.height)
            }
        }
        return button.bounds
    }

    private func showTooltip(for kind: MetricSegmentKind, button: NSStatusBarButton) {
        switch kind {
        case .cpu:
            showCpuUsageTooltip(button: button)
        case .cpuTemp:
            showCpuTempTooltip(button: button, kind: kind)
        case .memory:
            showMemoryTooltip(button: button)
        case .fan:
            showFanTooltip(button: button, kind: kind)
        case .network:
            showNetworkTooltip(button: button)
        case .battery:
            showBatteryTooltip(button: button, kind: kind)
        case .gpu:
            showGpuTooltip(button: button, kind: kind)
        case .gpuTemp:
            showGpuTempTooltip(button: button, kind: kind)
        }
    }

    private func showCpuUsageTooltip(button: NSStatusBarButton) {
        dismissActiveTip()
        CPUProcessPanel.shared.toggle(cpuUsage: String(format: "%.1f%%", manager.cpuUsage))
    }

    private func showCpuTempTooltip(button: NSStatusBarButton, kind: MetricSegmentKind) {
        let v = manager.cpuTemp
        let text = v > 0 ? "\(L10n.shared.moduleName(.cpuTemp)): \(String(format: "%.1f°C", v))" : "\(L10n.shared.moduleName(.cpuTemp)): N/A"
        showSimpleTooltip(text: text, button: button, rect: segmentRect(for: kind, in: button))
    }

    private func showMemoryTooltip(button: NSStatusBarButton) {
        dismissActiveTip()
        let mem = manager.memoryUsage
        let used = String(format: "%.1fGB", Double(mem.used) / 1_073_741_824)
        let total = String(format: "%.1fGB", Double(mem.total) / 1_073_741_824)
        MemoryProcessPanel.shared.toggle(memoryInfo: "\(used)/\(total) (\(String(format: "%.0f%%", mem.usedPercentage)))")
    }

    private func showFanTooltip(button: NSStatusBarButton, kind: MetricSegmentKind) {
        let fans = manager.fanSpeeds
        let l = L10n.shared
        let rect = segmentRect(for: kind, in: button)
        if fans.isEmpty {
            showSimpleTooltip(text: "\(l.moduleName(.fan)): N/A", button: button, rect: rect)
            return
        }
        let parts = fans.enumerated().map { "\(l.fanLabel($0.offset + 1)): \(Int($0.element.current)) RPM" }
        showSimpleTooltip(text: parts.joined(separator: "  "), button: button, rect: rect)
    }

    private func showNetworkTooltip(button: NSStatusBarButton) {
        dismissActiveTip()
        let s = manager.networkSpeed
        NetworkProcessPanel.shared.toggle(upload: s.uploadFormatted, download: s.downloadFormatted)
    }

    private func localizedGpuLabel(_ key: String) -> String {
        key == "discrete" ? L10n.shared.discreteGPU : L10n.shared.integratedGPU
    }

    private func showGpuTooltip(button: NSStatusBarButton, kind: MetricSegmentKind) {
        let gpus = GPUService.shared.allGPUUsages()
        let rect = segmentRect(for: kind, in: button)
        if gpus.isEmpty {
            showSimpleTooltip(text: "\(L10n.shared.moduleName(.gpuUsage)): N/A", button: button, rect: rect)
            return
        }
        let l = L10n.shared
        let parts = gpus.map { "\(localizedGpuLabel($0.name))\(l.usageLabel): \(String(format: "%.0f%%", $0.usage))" }
        showSimpleTooltip(text: parts.joined(separator: "\n"), button: button, rect: rect)
    }

    private func showGpuTempTooltip(button: NSStatusBarButton, kind: MetricSegmentKind) {
        let temps = GPUService.shared.allGPUTemperatures()
        let rect = segmentRect(for: kind, in: button)
        if temps.isEmpty {
            showSimpleTooltip(text: "\(L10n.shared.moduleName(.gpuTemp)): N/A", button: button, rect: rect)
            return
        }
        let l = L10n.shared
        let parts = temps.map { "\(localizedGpuLabel($0.label))\(l.temperatureLabel): \(String(format: "%.0f°C", $0.temp))" }
        showSimpleTooltip(text: parts.joined(separator: "\n"), button: button, rect: rect)
    }

    private func showSimpleTooltip(text: String, button: NSStatusBarButton, rect: NSRect) {
        dismissActiveTip()

        let tip = NSPopover()
        tip.behavior = .applicationDefined
        tip.animates = true
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        let lineCount = max(text.components(separatedBy: "\n").count, 1)
        let height = CGFloat(lineCount * 18 + 16)
        tip.contentSize = NSSize(width: 200, height: height)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: height))
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8)
        ])
        let vc = NSViewController()
        vc.view = container
        tip.contentViewController = vc
        tip.show(relativeTo: rect, of: button, preferredEdge: .minY)
        activeTip = tip
        installTipClickMonitor()
    }

    private func showBatteryTooltip(button: NSStatusBarButton, kind: MetricSegmentKind) {
        dismissActiveTip()

        let info = manager.batteryInfo
        let l = L10n.shared
        let tip = NSPopover()
        tip.behavior = .applicationDefined
        tip.animates = true

        let labelFont = NSFont.systemFont(ofSize: 12)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        var rows: [(String, String)] = []

        if info.adapterPowerWatts > 0 {
            let rated = info.adapterWatts > 0 ? " (\(l.ratedPower) \(info.adapterWatts)W)" : ""
            rows.append((l.adapterPower, String(format: "%.1fW%@", info.adapterPowerWatts, rated)))
        } else {
            rows.append((l.adapterLabel, l.notConnected))
        }

        let w = info.powerWatts
        let hint = w >= 0 ? l.chargingPrefix : l.dischargingPrefix
        rows.append((l.batteryPower, String(format: "%.1fW (%@)", abs(w), hint)))

        let absMa = abs(info.amperage)
        let currentStr: String
        if absMa >= 1000 {
            currentStr = String(format: "%.2fA", Double(absMa) / 1000.0)
        } else {
            currentStr = "\(absMa)mA"
        }
        let currentHint = info.amperage >= 0 ? l.chargingPrefix : l.dischargingPrefix
        rows.append((l.currentLabel, "\(currentStr) (\(currentHint))"))

        rows.append((l.voltageLabel, String(format: "%.1fV", Double(info.voltage) / 1000.0)))
        rows.append((l.batteryLevel, "\(info.percentage)%"))
        rows.append((l.cycleCountLabel, "\(info.cycleCount)"))
        rows.append((l.batteryHealth, "\(info.healthPercentage)%"))

        var labels: [NSTextField] = []
        var values: [NSTextField] = []

        for (labelText, valueText) in rows {
            let lbl = NSTextField(labelWithString: labelText.isEmpty ? "" : "\(labelText):")
            lbl.font = labelFont
            lbl.alignment = .right
            lbl.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(lbl)
            labels.append(lbl)

            let val = NSTextField(labelWithString: valueText)
            val.font = valueFont
            val.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(val)
            values.append(val)
        }

        let labelMaxW: CGFloat = labels.reduce(0) { max($0, $1.intrinsicContentSize.width) }
        let valueMaxW: CGFloat = values.reduce(0) { max($0, $1.intrinsicContentSize.width) }
        let totalW = 12 + labelMaxW + 6 + valueMaxW + 12

        for i in 0..<labels.count {
            let topAnchor = i == 0 ? container.topAnchor : labels[i - 1].bottomAnchor
            let topConst: CGFloat = i == 0 ? 10 : 4
            NSLayoutConstraint.activate([
                labels[i].topAnchor.constraint(equalTo: topAnchor, constant: topConst),
                labels[i].leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                labels[i].widthAnchor.constraint(equalToConstant: labelMaxW),
                values[i].centerYAnchor.constraint(equalTo: labels[i].centerYAnchor),
                values[i].leadingAnchor.constraint(equalTo: labels[i].trailingAnchor, constant: 6),
                values[i].trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            ])
        }

        let energySep = NSBox()
        energySep.boxType = .separator
        energySep.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(energySep)

        let energyTitle = NSTextField(labelWithString: "⚡ \(l.energyRanking)")
        energyTitle.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        energyTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(energyTitle)

        let lastLbl = labels.last!
        NSLayoutConstraint.activate([
            energySep.topAnchor.constraint(equalTo: lastLbl.bottomAnchor, constant: 8),
            energySep.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            energySep.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            energyTitle.topAnchor.constraint(equalTo: energySep.bottomAnchor, constant: 6),
            energyTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
        ])

        var energyIconViews: [NSImageView] = []
        var energyNameFields: [NSTextField] = []
        var energyRows: [NSView] = []
        var prevAnchor: NSLayoutYAxisAnchor = energyTitle.bottomAnchor

        for _ in 0..<3 {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(row)

            let iconView = NSImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.imageScaling = .scaleProportionallyUpOrDown
            row.addSubview(iconView)

            let nameField = NSTextField(labelWithString: "")
            nameField.font = labelFont
            nameField.translatesAutoresizingMaskIntoConstraints = false
            nameField.lineBreakMode = .byTruncatingTail
            row.addSubview(nameField)

            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: prevAnchor, constant: 4),
                row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                row.heightAnchor.constraint(equalToConstant: 18),
                iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 14),
                iconView.heightAnchor.constraint(equalToConstant: 14),
                nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
                nameField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                nameField.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            ])

            energyIconViews.append(iconView)
            energyNameFields.append(nameField)
            energyRows.append(row)
            prevAnchor = row.bottomAnchor
        }

        let bottomSpacer = NSView()
        bottomSpacer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bottomSpacer)
        NSLayoutConstraint.activate([
            bottomSpacer.topAnchor.constraint(equalTo: prevAnchor),
            bottomSpacer.heightAnchor.constraint(equalToConstant: 10),
            bottomSpacer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottomSpacer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        ])

        func updateEnergyRows() {
            let procs = EnergyService.shared.topProcesses(limit: 3)
            let hasData = !procs.isEmpty
            energySep.isHidden = !hasData
            energyTitle.isHidden = !hasData
            for i in 0..<3 {
                if i < procs.count {
                    energyIconViews[i].image = procs[i].icon
                    energyNameFields[i].stringValue = "\(i + 1). \(procs[i].name)"
                    energyRows[i].isHidden = false
                } else {
                    energyRows[i].isHidden = true
                }
            }
        }

        updateEnergyRows()

        let basicHeight: CGFloat = 10 + CGFloat(rows.count) * 18 + CGFloat(rows.count - 1) * 4
        let energyHeight: CGFloat = 99
        let height: CGFloat = basicHeight + energyHeight + 10
        tip.contentSize = NSSize(width: max(260, totalW), height: height)

        energyRefreshTimer?.invalidate()
        energyRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard self?.activeTip != nil else { return }
            updateEnergyRows()
        }

        let vc = NSViewController()
        vc.view = container
        tip.contentViewController = vc
        tip.show(relativeTo: segmentRect(for: kind, in: button), of: button, preferredEdge: .minY)
        activeTip = tip
        installTipClickMonitor()
    }

    private func dismissActiveTip() {
        energyRefreshTimer?.invalidate()
        energyRefreshTimer = nil
        if let monitor = tipClickMonitor {
            NSEvent.removeMonitor(monitor)
            tipClickMonitor = nil
        }
        activeTip?.performClose(nil)
        activeTip = nil
    }

    private func installTipClickMonitor() {
        if let monitor = tipClickMonitor {
            NSEvent.removeMonitor(monitor)
            tipClickMonitor = nil
        }
        tipClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismissActiveTip()
            }
        }
    }
}
