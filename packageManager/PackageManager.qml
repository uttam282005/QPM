pragma ComponentBehavior: Bound
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Pacman/AUR manager. Repo transactions run through pkexec (shell's polkit agent) with output streamed below;
// AUR builds open kitty + yay since they need PKGBUILD review and sudo on a tty.
Scope {
    id: root

    property var installed: []      // {name, version, size, explicit, desc, aur}
    property var updates: []        // {name, version, newVersion, aur}
    property var results: []        // {name, version, repo, desc}
    property bool showAll: false
    property string filter: ""
    property string log: ""
    readonly property bool busy: listProc.running || updatesProc.running || searchProc.running || txProc.running
    readonly property var installedNames: new Set(installed.map(p => p.name))

    function refresh() {
        listProc.running = true
        updatesProc.running = true
    }

    function search(q) {
        if (q.trim().length < 2) return
        searchProc.command = ["yay", "-Ss", "--topdown", "--color", "never", ...q.trim().split(/\s+/)]
        searchProc.running = true
    }

    function run(args, label) {
        if (txProc.running) return
        root.log = `$ ${label}\n`
        txProc.command = ["pkexec", "pacman", "--noconfirm", "--color", "never", ...args]
        txProc.running = true
    }

    function inTerminal(cmd) {
        aurProc.command = ["kitty", "--hold", "fish", "-i", "-l", "-c", cmd]
        aurProc.running = true
    }

    function install(pkg) {
        if (pkg.repo === "aur") inTerminal(`yay -S ${pkg.name}`)
        else run(["-S", "--needed", pkg.name], `install ${pkg.name}`)
    }
    function remove(name) { run(["-Rns", name], `remove ${name}`) }
    function upgradeRepo() { run(["-Syu"], "pacman -Syu") }
    function upgradeAur() { inTerminal("yay -Sua") }

    // Package names come from pacman/yay output; reject anything else before it reaches a shell.
    function safe(name) { return /^[a-z0-9@._+-]+$/i.test(name) }

    Process {
        id: listProc
        command: ["bash", "-c", "pacman -Qmq; echo '\x1e'; expac -Q '%n\t%v\t%m\t%w\t%d'"]
        stdout: StdioCollector {
            onStreamFinished: {
                const [foreign, rows] = text.split("\x1e\n")
                const aur = new Set(foreign.split("\n").filter(Boolean))
                root.installed = rows.split("\n").filter(Boolean).map(l => {
                    const [name, version, size, reason, desc] = l.split("\t")
                    return { name, version, size: parseInt(size), explicit: reason === "explicit", desc, aur: aur.has(name) }
                })
            }
        }
    }

    Process {
        id: updatesProc
        command: ["bash", "-c", "checkupdates --nocolor 2>/dev/null; echo '\x1e'; yay -Qua --color never 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                const parse = (block, aur) => block.split("\n").filter(l => l.includes(" -> ")).map(l => {
                    const [name, version, , newVersion] = l.trim().split(/\s+/)
                    return { name, version, newVersion, aur }
                })
                const [repo, aur] = text.split("\x1e")
                root.updates = [...parse(repo, false), ...parse(aur ?? "", true)]
            }
        }
    }

    Process {
        id: searchProc
        stdout: StdioCollector {
            onStreamFinished: {
                const out = []
                for (const l of text.split("\n")) {
                    const m = l.match(/^(\S+)\/(\S+) (\S+)/)
                    if (m) out.push({ repo: m[1], name: m[2], version: m[3], desc: "" })
                    else if (out.length && l.startsWith(" ")) out[out.length - 1].desc = l.trim()
                }
                root.results = out
            }
        }
    }

    Process {
        id: txProc
        stdout: SplitParser { onRead: l => root.log += l + "\n" }
        stderr: SplitParser { onRead: l => root.log += l + "\n" }
        onExited: (code, status) => {
            root.log += code === 0 ? "✓ done\n" : `✗ failed (exit ${code})\n`
            root.refresh()
            Updates.refresh()
        }
    }

    Process {
        id: aurProc
        onExited: { root.refresh(); Updates.refresh() }
    }

    function formatSize(b) {
        return b > 1e9 ? (b / 1e9).toFixed(1) + " GB" : b > 1e6 ? (b / 1e6).toFixed(1) + " MB" : Math.round(b / 1e3) + " KB"
    }

    Loader {
        active: GlobalStates.packageManagerOpen
        onActiveChanged: if (active) root.refresh()

        sourceComponent: PanelWindow {
            id: panelWindow
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "quickshell:packageManager"
            WlrLayershell.layer: WlrLayer.Top // below Overlay so the polkit prompt shows on top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
            color: "transparent"
            implicitWidth: 760
            implicitHeight: 640
            mask: Region { item: card }

            Component.onCompleted: GlobalFocusGrab.addDismissable(panelWindow)
            Component.onDestruction: GlobalFocusGrab.removeDismissable(panelWindow)
            Connections {
                target: GlobalFocusGrab
                function onDismissed() { GlobalStates.packageManagerOpen = false }
            }

            StyledRectangularShadow { target: card }

            Rectangle {
                id: card
                anchors.fill: parent
                anchors.margins: Appearance.sizes.elevationMargin
                radius: Appearance.rounding.large
                color: Appearance.colors.colUiBackground ?? Appearance.colors.colLayer0
                border.width: 1
                border.color: Appearance.colors.colLayer0Border
                focus: true
                Keys.onEscapePressed: GlobalStates.packageManagerOpen = false

                // Liquid glass backdrop if this config ships WindowGlass (end4-pC); plain translucent card otherwise.
                Loader {
                    anchors.fill: parent
                    source: Qt.resolvedUrl("../../common/widgets/WindowGlass.qml")
                    onLoaded: {
                        item.cardRadius = Qt.binding(() => card.radius)
                        item.tint = Qt.binding(() => card.color)
                    }
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 10

                    RowLayout {
                        Layout.fillWidth: true
                        MaterialSymbol { text: "package_2"; iconSize: Appearance.font.pixelSize.huge; color: Appearance.colors.colOnLayer0 }
                        StyledText {
                            Layout.fillWidth: true
                            text: "Packages"
                            font.pixelSize: Appearance.font.pixelSize.larger
                            color: Appearance.colors.colOnLayer0
                        }
                        StyledIndeterminateProgressBar { visible: root.busy; Layout.preferredWidth: 80 }
                        IconButton { symbol: "refresh"; onClicked: root.refresh() }
                        IconButton { symbol: "close"; onClicked: GlobalStates.packageManagerOpen = false }
                    }

                    SecondaryTabBar {
                        id: tabs
                        SecondaryTabButton { buttonIcon: "inventory_2"; buttonText: `Installed (${root.installed.length})` }
                        SecondaryTabButton { buttonIcon: "update"; buttonText: `Updates (${root.updates.length})` }
                        SecondaryTabButton { buttonIcon: "travel_explore"; buttonText: "Browse" }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        visible: tabs.currentIndex !== 1
                        MaterialTextField {
                            id: searchField
                            Layout.fillWidth: true
                            placeholderText: tabs.currentIndex === 2 ? "Search repos + AUR, press Enter" : "Filter installed"
                            onTextChanged: root.filter = text.toLowerCase()
                            onAccepted: if (tabs.currentIndex === 2) root.search(text)
                            Keys.onEscapePressed: GlobalStates.packageManagerOpen = false
                        }
                        PillButton {
                            visible: tabs.currentIndex === 0
                            text: root.showAll ? "All" : "Explicit"
                            onClicked: root.showAll = !root.showAll
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        visible: tabs.currentIndex === 1
                        StyledText {
                            Layout.fillWidth: true
                            color: Appearance.colors.colSubtext
                            text: root.updates.length === 0 ? "System is up to date" : "Arch doesn't support partial upgrades, so updates apply all at once."
                        }
                        PillButton {
                            visible: root.updates.some(u => !u.aur)
                            text: "Update repo packages"
                            primary: true
                            onClicked: root.upgradeRepo()
                        }
                        PillButton {
                            visible: root.updates.some(u => u.aur)
                            text: "Update AUR"
                            onClicked: root.upgradeAur()
                        }
                    }

                    ListView {
                        id: list
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        spacing: 4
                        ScrollBar.vertical: StyledScrollBar {}
                        model: {
                            const f = root.filter
                            if (tabs.currentIndex === 0)
                                return root.installed.filter(p => (root.showAll || p.explicit) && (!f || p.name.includes(f) || p.desc.toLowerCase().includes(f)))
                            if (tabs.currentIndex === 1) return root.updates
                            return root.results
                        }

                        delegate: Rectangle {
                            id: row
                            required property var modelData
                            readonly property bool isInstalled: tabs.currentIndex !== 2 || root.installedNames.has(modelData.name)
                            width: list.width - 8
                            implicitHeight: 52
                            radius: Appearance.rounding.normal
                            color: hover.hovered ? Appearance.colors.colLayer1Hover : ColorUtils.transparentize(Appearance.colors.colLayer1, 0.4)
                            HoverHandler { id: hover }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 8
                                spacing: 8
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    RowLayout {
                                        StyledText { text: row.modelData.name; color: Appearance.colors.colOnLayer1; font.weight: Font.DemiBold }
                                        StyledText {
                                            text: row.modelData.newVersion ? `${row.modelData.version} → ${row.modelData.newVersion}` : row.modelData.version
                                            color: Appearance.colors.colSubtext
                                            font.pixelSize: Appearance.font.pixelSize.smaller
                                        }
                                        Tag { visible: !!row.modelData.aur || row.modelData.repo === "aur"; text: "AUR" }
                                        Tag { visible: !!row.modelData.repo && row.modelData.repo !== "aur"; text: row.modelData.repo ?? "" }
                                        Tag { visible: tabs.currentIndex === 2 && row.isInstalled; text: "installed" }
                                    }
                                    StyledText {
                                        Layout.fillWidth: true
                                        visible: text !== ""
                                        text: row.modelData.desc ?? ""
                                        elide: Text.ElideRight
                                        color: Appearance.colors.colSubtext
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                    }
                                }
                                StyledText {
                                    visible: tabs.currentIndex === 0
                                    text: row.modelData.size ? root.formatSize(row.modelData.size) : ""
                                    color: Appearance.colors.colSubtext
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                }
                                IconButton {
                                    id: delBtn
                                    property bool armed: false // second click confirms removal
                                    visible: tabs.currentIndex === 0
                                    symbol: armed ? "check" : "delete"
                                    danger: true
                                    enabled: !txProc.running && root.safe(row.modelData.name)
                                    onClicked: armed ? root.remove(row.modelData.name) : (armed = true)
                                    Timer { running: delBtn.armed; interval: 3000; onTriggered: delBtn.armed = false }
                                }
                                IconButton {
                                    visible: tabs.currentIndex === 2 && !row.isInstalled
                                    symbol: "download"
                                    enabled: !txProc.running && root.safe(row.modelData.name)
                                    onClicked: root.install(row.modelData)
                                }
                            }
                        }

                        StyledText {
                            anchors.centerIn: parent
                            visible: list.count === 0 && !root.busy
                            text: tabs.currentIndex === 2 ? "Search for a package" : "Nothing here"
                            color: Appearance.colors.colSubtext
                        }
                    }

                    // Transaction log
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 120
                        visible: root.log !== ""
                        radius: Appearance.rounding.normal
                        color: ColorUtils.transparentize(Appearance.colors.colLayer0, 0.3)
                        ScrollView {
                            id: logScroll
                            anchors.fill: parent
                            anchors.margins: 8
                            TextArea {
                                readOnly: true
                                text: root.log
                                wrapMode: Text.WrapAnywhere
                                color: Appearance.colors.colOnLayer0
                                font.family: Appearance.font.family.monospace
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                background: null
                                onTextChanged: cursorPosition = length
                            }
                        }
                        IconButton {
                            anchors { top: parent.top; right: parent.right; margins: 4 }
                            visible: !txProc.running
                            symbol: "close"
                            onClicked: root.log = ""
                        }
                    }
                }
            }
        }
    }

    component IconButton: RippleButton {
        id: iconBtn
        property string symbol
        property bool danger: false
        implicitWidth: 34
        implicitHeight: 34
        buttonRadius: Appearance.rounding.full
        colBackground: "transparent"
        colBackgroundHover: Appearance.colors.colLayer1Hover
        opacity: enabled ? 1 : 0.4
        contentItem: MaterialSymbol {
            horizontalAlignment: Text.AlignHCenter
            text: iconBtn.symbol
            iconSize: Appearance.font.pixelSize.larger
            color: iconBtn.danger ? Appearance.m3colors.m3error : Appearance.colors.colOnLayer1
        }
    }

    component PillButton: RippleButton {
        id: pill
        property bool primary: false
        implicitHeight: 36
        horizontalPadding: 14
        buttonRadius: Appearance.rounding.full
        enabled: !txProc.running
        opacity: enabled ? 1 : 0.5
        colBackground: primary ? Appearance.colors.colPrimary : Appearance.colors.colSecondaryContainer
        colBackgroundHover: primary ? Appearance.colors.colPrimaryHover : Appearance.colors.colSecondaryContainerHover
        contentItem: StyledText {
            horizontalAlignment: Text.AlignHCenter
            text: pill.text
            color: pill.primary ? Appearance.colors.colOnPrimary : Appearance.colors.colOnSecondaryContainer
        }
    }

    component Tag: Rectangle {
        property alias text: tagText.text
        implicitWidth: tagText.implicitWidth + 12
        implicitHeight: tagText.implicitHeight + 2
        radius: Appearance.rounding.full
        color: Appearance.colors.colSecondaryContainer
        StyledText {
            id: tagText
            anchors.centerIn: parent
            color: Appearance.colors.colOnSecondaryContainer
            font.pixelSize: Appearance.font.pixelSize.smallest
        }
    }

    IpcHandler {
        target: "packageManager"
        function toggle(): void { GlobalStates.packageManagerOpen = !GlobalStates.packageManagerOpen }
    }
}
