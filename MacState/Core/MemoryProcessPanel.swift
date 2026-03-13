import AppKit

@MainActor
final class MemoryProcessPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = MemoryProcessPanel()

    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var summaryLabel: NSTextField?
    private var processes: [ProcessMemoryUsage] = []
    private var refreshTimer: Timer?
    private var detailPanel: NSWindow?
    private var lastMemoryInfo: String = ""

    private let iconColumnID = NSUserInterfaceItemIdentifier("memIcon")
    private let pidColumnID = NSUserInterfaceItemIdentifier("memPid")
    private let nameColumnID = NSUserInterfaceItemIdentifier("memName")
    private let usageColumnID = NSUserInterfaceItemIdentifier("memUsage")
    private let commandColumnID = NSUserInterfaceItemIdentifier("memCommand")

    private override init() {
        super.init()
    }

    func toggle(memoryInfo: String) {
        if let p = panel, p.isVisible {
            stopRefreshTimer()
            p.orderOut(nil)
            return
        }
        show(memoryInfo: memoryInfo)
    }

    private func show(memoryInfo: String) {
        lastMemoryInfo = memoryInfo

        if panel == nil {
            buildPanel()
        }

        guard let panel = panel, let tableView = tableView, let summaryLabel = summaryLabel else { return }

        panel.title = "\(L10n.shared.moduleName(.memory)) — \(L10n.shared.topProcesses)"
        updateColumnTitlesForLanguage()
        summaryLabel.stringValue = "\(L10n.shared.moduleName(.memory)): \(memoryInfo)"

        DispatchQueue.global(qos: .userInitiated).async {
            let result = ProcessMemoryService.shared.topProcesses(limit: 10)
            DispatchQueue.main.async {
                self.processes = result
                tableView.reloadData()
                self.positionPanel(panel)
                panel.makeKeyAndOrderFront(nil)
                self.startRefreshTimer()
            }
        }
    }

    private func startRefreshTimer() {
        stopRefreshTimer()
        let interval = MonitorManager.shared.refreshInterval
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshData()
            }
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshData() {
        guard let panel = panel, panel.isVisible, let tableView = tableView else {
            stopRefreshTimer()
            return
        }

        let mem = MonitorManager.shared.memoryUsage
        let used = String(format: "%.1fGB", Double(mem.used) / 1_073_741_824)
        let total = String(format: "%.1fGB", Double(mem.total) / 1_073_741_824)
        lastMemoryInfo = "\(used)/\(total) (\(String(format: "%.0f%%", mem.usedPercentage)))"
        summaryLabel?.stringValue = "\(L10n.shared.moduleName(.memory)): \(lastMemoryInfo)"

        DispatchQueue.global(qos: .userInitiated).async {
            let result = ProcessMemoryService.shared.topProcesses(limit: 10)
            DispatchQueue.main.async { [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.processes = result
                tableView.reloadData()
            }
        }
    }

    private func buildPanel() {
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.title = "\(L10n.shared.moduleName(.memory)) — \(L10n.shared.topProcesses)"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 800, height: 500)

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        p.contentView = contentView

        let summary = NSTextField(labelWithString: "")
        summary.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        summary.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(summary)
        self.summaryLabel = summary

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separator)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        contentView.addSubview(scrollView)

        let table = ClickableTableView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.headerView = NSTableHeaderView()
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autosaveName = "MemoryProcessTable"
        table.autosaveTableColumns = true

        let iconCol = NSTableColumn(identifier: iconColumnID)
        iconCol.title = ""
        iconCol.width = 20
        iconCol.minWidth = 20
        iconCol.maxWidth = 40
        iconCol.resizingMask = [.userResizingMask]
        table.addTableColumn(iconCol)

        let pidCol = NSTableColumn(identifier: pidColumnID)
        pidCol.title = "PID"
        pidCol.minWidth = 40
        pidCol.width = 50
        pidCol.resizingMask = [.userResizingMask]
        table.addTableColumn(pidCol)

        let nameCol = NSTableColumn(identifier: nameColumnID)
        nameCol.title = L10n.shared.processName
        nameCol.minWidth = 120
        nameCol.width = 300
        nameCol.resizingMask = [.userResizingMask, .autoresizingMask]
        table.addTableColumn(nameCol)

        let usageCol = NSTableColumn(identifier: usageColumnID)
        usageCol.title = L10n.shared.memory
        usageCol.minWidth = 60
        usageCol.width = 80
        usageCol.resizingMask = [.userResizingMask]
        table.addTableColumn(usageCol)

        let commandCol = NSTableColumn(identifier: commandColumnID)
        commandCol.title = "命令行"
        commandCol.headerCell.alignment = .center
        commandCol.minWidth = 50
        commandCol.width = 70
        commandCol.resizingMask = [.userResizingMask]
        table.addTableColumn(commandCol)

        table.target = self
        table.action = #selector(tableRowClicked)

        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        self.tableView = table

        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            summary.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
        ])
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
        ])
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        self.panel = p
        p.setFrameAutosaveName("MemoryProcessPanel")
    }

    private func positionPanel(_ p: NSPanel) {
        if p.frameAutosaveName.isEmpty || !p.setFrameUsingName(p.frameAutosaveName) {
            guard let screen = NSScreen.main else { return }
            let visibleFrame = screen.visibleFrame
            let panelFrame = p.frame
            let x = visibleFrame.midX - panelFrame.width / 2
            let y = visibleFrame.midY - panelFrame.height / 2
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        return MainActor.assumeIsolated { processes.count }
    }

    nonisolated func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        return MainActor.assumeIsolated {
            guard row < processes.count, let columnID = tableColumn?.identifier else { return nil }
            let proc = processes[row]

            if columnID == iconColumnID {
                let imageView = NSImageView()
                imageView.image = proc.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
                imageView.imageScaling = .scaleProportionallyUpOrDown
                return centeredContainer(imageView, size: NSSize(width: 16, height: 16))
            }

            if columnID == pidColumnID {
                let cell = NSTextField(labelWithString: "\(proc.pid)")
                cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                cell.textColor = .secondaryLabelColor
                return centeredContainer(cell)
            }

            if columnID == nameColumnID {
                let cell = NSTextField(labelWithString: proc.name)
                cell.font = NSFont.systemFont(ofSize: 12)
                cell.lineBreakMode = .byTruncatingTail
                return centeredContainer(cell)
            }

            if columnID == usageColumnID {
                let cell = NSTextField(labelWithString: proc.memoryFormatted)
                cell.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                cell.alignment = .right
                return centeredContainer(cell)
            }

            if columnID == commandColumnID {
                let cell = ClickableLabel(title: L10n.shared.viewButton)
                cell.toolTip = proc.command
                let cmd = proc.command
                cell.onClickAction = { [weak self] in
                    self?.showCommandDetail(cmd)
                }
                return centeredContainer(cell)
            }

            return nil
        }
    }

    private func centeredContainer(_ child: NSView, size: NSSize? = nil) -> NSView {
        let container = NSView()
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        if let size = size {
            NSLayoutConstraint.activate([
                child.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                child.widthAnchor.constraint(equalToConstant: size.width),
                child.heightAnchor.constraint(equalToConstant: size.height),
            ])
        } else {
            NSLayoutConstraint.activate([
                child.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        return container
    }

    private func updateColumnTitlesForLanguage() {
        guard let tableView = tableView else { return }
        let l = L10n.shared
        for col in tableView.tableColumns {
            if col.identifier == nameColumnID {
                col.title = l.processName
            } else if col.identifier == usageColumnID {
                col.title = l.memory
            } else if col.identifier == commandColumnID {
                col.title = l.commandLine
            }
        }
    }

    @objc private func tableRowClicked() {
        guard let tableView = tableView else { return }
        let row = tableView.clickedRow
        let col = tableView.clickedColumn
        guard row >= 0, row < processes.count else { return }
        if col >= 0, tableView.tableColumns[col].identifier == commandColumnID {
            showCommandDetail(processes[row].command)
        }
    }

    private func showCommandDetail(_ command: String) {
        detailPanel?.orderOut(nil)
        detailPanel = nil

        let dp = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        dp.title = L10n.shared.commandLine
        dp.isReleasedWhenClosed = false
        dp.minSize = NSSize(width: 300, height: 200)
        dp.level = .modalPanel

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width, .height]

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = command
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        dp.contentView = scrollView

        dp.center()

        self.detailPanel = dp
        NSApp.activate(ignoringOtherApps: true)
        dp.makeKeyAndOrderFront(nil)
    }
}
