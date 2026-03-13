import AppKit

@MainActor
final class NetworkProcessPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = NetworkProcessPanel()

    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var summaryLabel: NSTextField?
    private var processes: [ProcessNetworkUsage] = []
    private var expandedPid: Int32? = nil
    private var expandedConnections: [ConnectionInfo] = []
    private var refreshTimer: Timer?
    private var detailPanel: NSWindow?
    private var lastUpload: String = ""
    private var lastDownload: String = ""

    private enum SortMode {
        case defaultOrder
        case uploadDesc
        case uploadAsc
        case downloadDesc
        case downloadAsc
    }
    private var sortMode: SortMode = .defaultOrder

    private let iconColumnID = NSUserInterfaceItemIdentifier("netIcon")
    private let pidColumnID = NSUserInterfaceItemIdentifier("netPid")
    private let nameColumnID = NSUserInterfaceItemIdentifier("netName")
    private let geoColumnID = NSUserInterfaceItemIdentifier("netGeo")
    private let uploadColumnID = NSUserInterfaceItemIdentifier("netUpload")
    private let downloadColumnID = NSUserInterfaceItemIdentifier("netDownload")
    private let commandColumnID = NSUserInterfaceItemIdentifier("netCommand")

    private override init() {
        super.init()
    }

    func toggle(upload: String, download: String) {
        if let p = panel, p.isVisible {
            stopRefreshTimer()
            p.orderOut(nil)
            return
        }
        show(upload: upload, download: download)
    }

    private func show(upload: String, download: String) {
        let l = L10n.shared
        lastUpload = upload
        lastDownload = download

        if panel == nil {
            buildPanel()
        }

        guard let panel = panel, let tableView = tableView, let summaryLabel = summaryLabel else { return }

        panel.title = "\(l.moduleName(.network)) — \(l.topProcesses)"
        updateColumnTitlesForLanguage()
        summaryLabel.stringValue = "\(l.upload): \(upload)  \(l.download): \(download)"
        expandedPid = nil
        expandedConnections = []

        DispatchQueue.global(qos: .userInitiated).async {
            let result = ProcessNetworkService.shared.topProcesses(limit: 10)
            DispatchQueue.main.async {
                self.processes = result
                self.sortProcesses()
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

        let l = L10n.shared
        let speed = MonitorManager.shared.networkSpeed
        lastUpload = speed.uploadFormatted
        lastDownload = speed.downloadFormatted
        summaryLabel?.stringValue = "\(l.upload): \(lastUpload)  \(l.download): \(lastDownload)"

        DispatchQueue.global(qos: .userInitiated).async {
            let result = ProcessNetworkService.shared.topProcesses(limit: 10)
            DispatchQueue.main.async { [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.processes = result
                self.sortProcesses()
                self.rebuildRowItems()
                tableView.reloadData()
            }
        }
    }

    private func buildPanel() {
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 500),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.title = "\(L10n.shared.moduleName(.network)) — \(L10n.shared.topProcesses)"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 1100, height: 500)

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
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.autosaveName = "NetworkProcessTableV4"
        table.autosaveTableColumns = false
        table.target = self
        table.action = #selector(tableRowClicked)

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
        nameCol.minWidth = 300
        nameCol.width = 420
        nameCol.resizingMask = [.userResizingMask]
        table.addTableColumn(nameCol)

        let geoCol = NSTableColumn(identifier: geoColumnID)
        geoCol.title = "归属地"
        geoCol.minWidth = 80
        geoCol.width = 160
        geoCol.resizingMask = [.userResizingMask, .autoresizingMask]
        table.addTableColumn(geoCol)

        let uploadCol = NSTableColumn(identifier: uploadColumnID)
        uploadCol.title = L10n.shared.upload
        uploadCol.headerCell.alignment = .left
        uploadCol.minWidth = 80
        uploadCol.width = 100
        uploadCol.resizingMask = [.userResizingMask]
        table.addTableColumn(uploadCol)

        let downloadCol = NSTableColumn(identifier: downloadColumnID)
        downloadCol.title = L10n.shared.download
        downloadCol.headerCell.alignment = .left
        downloadCol.minWidth = 80
        downloadCol.width = 100
        downloadCol.resizingMask = [.userResizingMask]
        table.addTableColumn(downloadCol)

        let commandCol = NSTableColumn(identifier: commandColumnID)
        commandCol.title = "命令行"
        commandCol.headerCell.alignment = .center
        commandCol.minWidth = 50
        commandCol.width = 70
        commandCol.resizingMask = [.userResizingMask]
        table.addTableColumn(commandCol)

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
        p.setFrameAutosaveName("NetworkProcessPanel")
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

    // MARK: - Row Data Model

    private enum RowItem {
        case process(ProcessNetworkUsage)
        case connection(ConnectionInfo)
    }

    private func rowItems() -> [RowItem] {
        var items: [RowItem] = []
        for proc in processes {
            items.append(.process(proc))
            if proc.pid == expandedPid {
                for conn in expandedConnections {
                    items.append(.connection(conn))
                }
            }
        }
        return items
    }

    private var cachedRowItems: [RowItem] = []

    private func rebuildRowItems() {
        cachedRowItems = rowItems()
    }

    // MARK: - Click Handler

    @objc private func tableRowClicked() {
        guard let tableView = tableView else { return }
        let row = tableView.clickedRow
        let col = tableView.clickedColumn
        guard row >= 0, row < cachedRowItems.count else { return }

        if case .process(let proc) = cachedRowItems[row] {
            if col >= 0, tableView.tableColumns[col].identifier == commandColumnID {
                showCommandDetail(proc.command)
                return
            }

            if expandedPid == proc.pid {
                expandedPid = nil
                expandedConnections = []
            } else {
                expandedPid = proc.pid
                DispatchQueue.global(qos: .userInitiated).async {
                    let conns = ConnectionService.shared.connections(forPid: proc.pid)
                        .filter { $0.state != "CLOSED" }
                        .sorted { ($0.state == "LISTEN" ? 0 : 1) < ($1.state == "LISTEN" ? 0 : 1) }
                    DispatchQueue.main.async {
                        self.expandedConnections = conns
                        self.rebuildRowItems()
                        tableView.reloadData()
                    }
                }
                return
            }
            rebuildRowItems()
            tableView.reloadData()
        }
    }

    // MARK: - NSTableViewDataSource

    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        return MainActor.assumeIsolated {
            rebuildRowItems()
            return cachedRowItems.count
        }
    }

    // MARK: - NSTableViewDelegate

    nonisolated func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        return MainActor.assumeIsolated {
            guard row < cachedRowItems.count, let columnID = tableColumn?.identifier else { return nil }

            switch cachedRowItems[row] {
            case .process(let proc):
                return processCell(proc: proc, columnID: columnID)
            case .connection(let conn):
                return connectionCell(conn: conn, columnID: columnID)
            }
        }
    }

    nonisolated func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return MainActor.assumeIsolated {
            guard row < cachedRowItems.count else { return 22 }
            switch cachedRowItems[row] {
            case .process: return 22
            case .connection: return 18
            }
        }
    }

    // MARK: - Cell Builders

    private func processCell(proc: ProcessNetworkUsage, columnID: NSUserInterfaceItemIdentifier) -> NSView? {
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
            let expanded = (proc.pid == expandedPid)
            let arrow = expanded ? "▼ " : "▶ "
            let cell = NSTextField(labelWithString: "\(arrow)\(proc.name)")
            cell.font = NSFont.systemFont(ofSize: 12)
            cell.lineBreakMode = .byTruncatingTail
            return centeredContainer(cell)
        }

        if columnID == geoColumnID {
            return NSView()
        }

        if columnID == uploadColumnID {
            let cell = NSTextField(labelWithString: "↑\(ProcessNetworkService.formatBytes(proc.uploadBytesPerSec))")
            cell.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            cell.alignment = .left
            return centeredContainer(cell)
        }

        if columnID == downloadColumnID {
            let cell = NSTextField(labelWithString: "↓\(ProcessNetworkService.formatBytes(proc.downloadBytesPerSec))")
            cell.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            cell.alignment = .left
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

    // MARK: - Sort

    private func sortProcesses() {
        switch sortMode {
        case .defaultOrder:
            break
        case .uploadDesc:
            processes.sort { $0.uploadBytesPerSec > $1.uploadBytesPerSec }
        case .uploadAsc:
            processes.sort { $0.uploadBytesPerSec < $1.uploadBytesPerSec }
        case .downloadDesc:
            processes.sort { $0.downloadBytesPerSec > $1.downloadBytesPerSec }
        case .downloadAsc:
            processes.sort { $0.downloadBytesPerSec < $1.downloadBytesPerSec }
        }
    }

    private func handleColumnClick(_ tableColumn: NSTableColumn) {
        guard let tableView = tableView else { return }
        if tableColumn.identifier == uploadColumnID {
            switch sortMode {
            case .uploadDesc: sortMode = .uploadAsc
            case .uploadAsc: sortMode = .defaultOrder
            default: sortMode = .uploadDesc
            }
        } else if tableColumn.identifier == downloadColumnID {
            switch sortMode {
            case .downloadDesc: sortMode = .downloadAsc
            case .downloadAsc: sortMode = .defaultOrder
            default: sortMode = .downloadDesc
            }
        } else {
            return
        }
        updateColumnTitles()
        sortProcesses()
        rebuildRowItems()
        tableView.reloadData()
    }

    private func updateColumnTitles() {
        guard let tableView = tableView else { return }
        let l = L10n.shared
        for col in tableView.tableColumns {
            if col.identifier == uploadColumnID {
                switch sortMode {
                case .uploadDesc: col.title = "\(l.upload) ↓"
                case .uploadAsc: col.title = "\(l.upload) ↑"
                default: col.title = l.upload
                }
            } else if col.identifier == downloadColumnID {
                switch sortMode {
                case .downloadDesc: col.title = "\(l.download) ↓"
                case .downloadAsc: col.title = "\(l.download) ↑"
                default: col.title = l.download
                }
            }
        }
    }

    private func updateColumnTitlesForLanguage() {
        guard let tableView = tableView else { return }
        let l = L10n.shared
        for col in tableView.tableColumns {
            if col.identifier == nameColumnID {
                col.title = l.processName
            } else if col.identifier == geoColumnID {
                col.title = l.geoLocation
            } else if col.identifier == commandColumnID {
                col.title = l.commandLine
            }
        }
        updateColumnTitles()
    }

    nonisolated func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        MainActor.assumeIsolated {
            handleColumnClick(tableColumn)
        }
    }

    private func connectionCell(conn: ConnectionInfo, columnID: NSUserInterfaceItemIdentifier) -> NSView? {
        if columnID == iconColumnID {
            return NSView()
        }

        if columnID == pidColumnID {
            return NSView()
        }

        if columnID == nameColumnID {
            let stateStr = conn.state.isEmpty ? "" : " [\(conn.state)]"
            let local = "\(conn.localAddress):\(conn.localPort)"
            let remote = conn.remotePort > 0 ? "\(conn.remoteAddress):\(conn.remotePort)" : conn.remoteAddress
            let text = "    \(conn.protocolName)\(stateStr)  \(local) → \(remote)"
            let cell = NSTextField(labelWithString: text)
            cell.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            cell.textColor = .secondaryLabelColor
            cell.lineBreakMode = .byTruncatingTail
            cell.toolTip = text
            return centeredContainer(cell)
        }

        if columnID == geoColumnID {
            if conn.remoteGeo.isEmpty {
                return NSView()
            }
            let cell = NSTextField(labelWithString: conn.remoteGeo)
            cell.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            cell.textColor = .tertiaryLabelColor
            cell.lineBreakMode = .byTruncatingTail
            cell.toolTip = conn.remoteGeo
            return centeredContainer(cell)
        }

        if columnID == uploadColumnID {
            return NSView()
        }

        if columnID == downloadColumnID {
            return NSView()
        }

        if columnID == commandColumnID {
            return NSView()
        }

        return nil
    }
}
