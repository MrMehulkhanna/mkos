// Drag-to-arrange screens, the way Windows and macOS display settings do it.
//
// Every screen is drawn to scale at its real position. Drag one anywhere —
// beside, above, below another — and on release it snaps edge to edge with
// the nearest screen without overlapping, then the layout is applied. The
// PC whose mouse and keyboard are shared (lan-mouse) sits as a dashed tile
// on its side; drag it to the other side to move it there.
import QtQuick
import "root:/Config"

Item {
    id: root
    property var screens: []          // [{name, model, x, y, w, h}] logical px
    property var mousePeers: ({})     // {left: "omen", right: "..."}
    signal placed(var positions)      // ["NAME=X,Y", ...]
    signal mouseSide(string from, string to)

    implicitHeight: 220

    // layout bounds, with room on both sides for the mouse-shared PCs
    readonly property real minX: screens.length ? Math.min.apply(null, screens.map(s => s.x)) : 0
    readonly property real minY: screens.length ? Math.min.apply(null, screens.map(s => s.y)) : 0
    readonly property real maxX: screens.length ? Math.max.apply(null, screens.map(s => s.x + s.w)) : 1
    readonly property real maxY: screens.length ? Math.max.apply(null, screens.map(s => s.y + s.h)) : 1
    readonly property real ghostW: 1280
    readonly property real k: Math.min((width - 24) / (maxX - minX + 2 * ghostW + 400),
                                       (height - 24) / (maxY - minY + 200))
    readonly property real ox: (width - (maxX - minX) * k) / 2 - minX * k
    readonly property real oy: (height - (maxY - minY) * k) / 2 - minY * k

    function overlaps(a, list) {
        return list.some(b => a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y)
    }
    // nearest spot touching another screen, edge to edge, overlapping none
    function snap(d, others) {
        if (!others.length) return { x: 0, y: 0 }
        // generous: screens side by side almost always want their tops in line
        const near = (v, t) => Math.abs(v - t) < Math.max(d.h, d.w) * 0.35
        let best = null, bestDist = 1e18
        for (const o of others) {
            const ys = [o.y, o.y + o.h - d.h, Math.min(Math.max(d.y, o.y - d.h + 1), o.y + o.h - 1)]
            const xs = [o.x, o.x + o.w - d.w, Math.min(Math.max(d.x, o.x - d.w + 1), o.x + o.w - 1)]
            const cands = []
            for (const y of ys) { cands.push({ x: o.x - d.w, y }); cands.push({ x: o.x + o.w, y }) }
            for (const x of xs) { cands.push({ x, y: o.y - d.h }); cands.push({ x, y: o.y + o.h }) }
            for (const c of cands) {
                // pull to aligned edges when close, like the OS dialogs do
                if (near(c.y, o.y)) c.y = o.y
                if (near(c.y + d.h, o.y + o.h)) c.y = o.y + o.h - d.h
                if (near(c.x, o.x)) c.x = o.x
                if (near(c.x + d.w, o.x + o.w)) c.x = o.x + o.w - d.w
                const r = { x: c.x, y: c.y, w: d.w, h: d.h }
                if (overlaps(r, others)) continue
                const dist = (c.x - d.x) ** 2 + (c.y - d.y) ** 2
                if (dist < bestDist) { bestDist = dist; best = c }
            }
        }
        return best || { x: d.x, y: d.y }
    }
    function drop(name, lx, ly) {
        const d = screens.find(s => s.name === name)
        const others = screens.filter(s => s.name !== name)
        const p = snap({ x: Math.round(lx), y: Math.round(ly), w: d.w, h: d.h }, others)
        const all = others.map(s => ({ name: s.name, x: s.x, y: s.y })).concat([{ name, x: p.x, y: p.y }])
        const mx = Math.min.apply(null, all.map(s => s.x)), my = Math.min.apply(null, all.map(s => s.y))
        placed(all.map(s => `${s.name}=${s.x - mx},${s.y - my}`))
    }

    Repeater {
        model: root.screens
        delegate: Rectangle {
            id: tile
            required property var modelData
            readonly property bool shared: modelData.name.startsWith("HEADLESS")
            x: root.ox + modelData.x * root.k
            y: root.oy + modelData.y * root.k
            width: modelData.w * root.k - 3; height: modelData.h * root.k - 3
            radius: 6
            color: drag.active ? Theme.alpha(Theme.accent, 0.28) : Theme.alpha(shared ? Theme.purple : Theme.accent, 0.13)
            border.width: drag.active ? 2 : 1
            border.color: shared ? Theme.purple : Theme.accent
            z: drag.active ? 10 : 1
            Behavior on x { enabled: !drag.active; NumberAnimation { duration: Theme.normal; easing.type: Theme.easeMove } }
            Behavior on y { enabled: !drag.active; NumberAnimation { duration: Theme.normal; easing.type: Theme.easeMove } }
            Column {
                anchors.centerIn: parent; spacing: 2
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: tile.shared ? "Shared screen" : tile.modelData.model
                    color: Theme.text; font.family: Theme.font; font.pixelSize: Theme.fontSm; font.weight: Font.DemiBold
                    elide: Text.ElideRight; width: Math.min(implicitWidth, tile.width - 10)
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: tile.modelData.w + " × " + tile.modelData.h
                    color: Theme.muted; font.family: Theme.font; font.pixelSize: Theme.fontXs
                }
            }
            MouseArea {
                id: drag_
                anchors.fill: parent
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                drag.target: tile
                onReleased: {
                    root.drop(tile.modelData.name, (tile.x - root.ox) / root.k, (tile.y - root.oy) / root.k)
                    // back under the binding: the new layout moves it, and a
                    // drop that changes nothing puts it back where it was
                    tile.x = Qt.binding(() => root.ox + tile.modelData.x * root.k)
                    tile.y = Qt.binding(() => root.oy + tile.modelData.y * root.k)
                }
            }
            readonly property alias drag: drag_.drag
        }
    }

    // the PCs reached by moving the mouse off an edge — on any side; drag
    // one to another side (left, right, above, below) to move it there
    Repeater {
        model: ["left", "right", "top", "bottom"].filter(s => !!root.mousePeers[s])
        delegate: Rectangle {
            id: ghost
            required property string modelData
            readonly property real gw: root.ghostW * 0.75 * root.k
            readonly property real gh: 720 * 0.75 * root.k
            readonly property real homeX: modelData === "left" ? root.ox + root.minX * root.k - gw - 14
                : modelData === "right" ? root.ox + root.maxX * root.k + 14
                : root.ox + (root.minX + root.maxX) / 2 * root.k - gw / 2
            readonly property real homeY: modelData === "top" ? root.oy + root.minY * root.k - gh - 10
                : modelData === "bottom" ? root.oy + root.maxY * root.k + 10
                : root.oy + root.minY * root.k
            x: homeX; y: homeY
            width: gw; height: gh
            radius: 6
            color: Theme.alpha(Theme.text, 0.05)
            border.width: 1; border.color: Theme.muted
            Behavior on x { enabled: !gm.drag.active; NumberAnimation { duration: Theme.normal; easing.type: Theme.easeMove } }
            Behavior on y { enabled: !gm.drag.active; NumberAnimation { duration: Theme.normal; easing.type: Theme.easeMove } }
            Column {
                anchors.centerIn: parent; spacing: 2
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.mousePeers[ghost.modelData]
                    color: Theme.text2; font.family: Theme.font; font.pixelSize: Theme.fontSm; font.weight: Font.DemiBold
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "mouse & keyboard"
                    color: Theme.muted; font.family: Theme.font; font.pixelSize: Theme.fontXs
                }
            }
            MouseArea {
                id: gm
                anchors.fill: parent
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                drag.target: ghost
                onReleased: {
                    // the side of the layout the tile was dropped nearest
                    const cx = ghost.x + ghost.width / 2, cy = ghost.y + ghost.height / 2
                    const l = root.ox + root.minX * root.k, r = root.ox + root.maxX * root.k
                    const t = root.oy + root.minY * root.k, b = root.oy + root.maxY * root.k
                    const d = { left: l - cx, right: cx - r, top: t - cy, bottom: cy - b }
                    const to = Object.keys(d).reduce((a, k) => d[k] > d[a] ? k : a, "left")
                    if (to !== ghost.modelData) root.mouseSide(ghost.modelData, to)
                    ghost.x = Qt.binding(() => ghost.homeX)
                    ghost.y = Qt.binding(() => ghost.homeY)
                }
            }
        }
    }
}
