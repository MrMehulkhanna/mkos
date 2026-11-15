pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

// PipeWire default sink/source. Event-driven — no polling.
Singleton {
    id: root

    readonly property var sink:   Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource
    PwObjectTracker { objects: [root.sink, root.source] }

    readonly property real volume:  sink && sink.audio ? sink.audio.volume : 0
    readonly property bool muted:   sink && sink.audio ? sink.audio.muted : false
    readonly property real micVolume: source && source.audio ? source.audio.volume : 0
    readonly property bool micMuted:  source && source.audio ? source.audio.muted : false
    readonly property string sinkName:   sink ? (sink.description || sink.nickname || sink.name || "Output") : "No output"
    readonly property string sourceName: source ? (source.description || source.nickname || source.name || "Input") : "No input"

    readonly property bool micInUse: Pipewire.nodes.values.some(n => !n.isSink && n.isStream)
    readonly property string micIcon: micMuted ? "mic-off" : "mic"
    readonly property string icon: muted || volume <= 0.001 ? "volume-mute"
                                 : volume < 0.34 ? "volume-low"
                                 : volume < 0.67 ? "volume-mid" : "volume-high"

    function setVolume(v)  { if (sink && sink.audio) { sink.audio.muted = false; sink.audio.volume = Math.max(0, Math.min(1, v)) } }
    function toggleMute()  { if (sink && sink.audio) sink.audio.muted = !sink.audio.muted }
    function step(d)       { setVolume(volume + d) }
    function setMicVolume(v) { if (source && source.audio) source.audio.volume = Math.max(0, Math.min(1, v)) }
    function toggleMicMute() { if (source && source.audio) source.audio.muted = !source.audio.muted }

    // sinks / sources for the output-device picker
    readonly property var sinks:   Pipewire.nodes.values.filter(n => n.isSink && !n.isStream && n.audio)
    readonly property var sources: Pipewire.nodes.values.filter(n => !n.isSink && !n.isStream && n.audio)
    // Set the default once, through WirePlumber (which remembers it), and do
    // not hold a Quickshell "preferred" node: Quickshell re-applies that
    // preference whenever the default changes, which overrode the outputs
    // Praxis picks on purpose (speakers in step with a shared screen, all
    // speakers together) moments after they were chosen.
    Component.onCompleted: {
        Pipewire.preferredDefaultAudioSink = null
        Pipewire.preferredDefaultAudioSource = null
    }
    function setDefaultSink(node) {
        if (node && node.id) {
            Quickshell.execDetached(["wpctl", "set-default", String(node.id)])
        }
    }
    function setDefaultSource(node) {
        if (node && node.id) {
            Quickshell.execDetached(["wpctl", "set-default", String(node.id)])
        }
    }

    // ── auto-switch when a headset/BT device appears or disappears ──────
    function _isExternal(n) {
        if (!n) return false
        const d = ((n.description || "") + " " + (n.nickname || "") + " " + (n.name || "")).toLowerCase()
        if (d.includes("bluez") || d.includes("bluetooth") || d.includes("headphone") ||
            d.includes("headset") || d.includes("earphone") || d.includes("airpod") || d.includes("buds")) {
            return true
        }
        return !d.includes("built-in") && !d.includes("hda") && !d.includes("speaker") && !d.includes("hdmi")
    }
    function _bestSink() {
        // prefer external (BT/USB/headphone), fall back to speaker / first sink
        const ext = sinks.find(n => _isExternal(n) && !String(n.name || "").startsWith("praxis-"))
        if (ext) return ext
        const speaker = sinks.find(n => {
            const d = ((n.description || "") + " " + (n.nickname || "") + " " + (n.name || "")).toLowerCase()
            return d.includes("speaker")
        })
        return speaker || sinks[0] || null
    }
    function _bestSource() {
        // never a speaker monitor or a Praxis output as "the microphone":
        // either records silence (or your own speakers), so the mic looks dead
        const ext = sources.find(n => _isExternal(n) && !String(n.name || "").endsWith(".monitor")
                                        && !String(n.name || "").startsWith("praxis-"))
        return ext || sources[0] || null
    }

    // Watch sinks list length — fires when a device plugs in or out
    onSinksChanged: {
        // Leave Praxis's own outputs alone: "All selected speakers" and the
        // in-step delay used while sharing are picked on purpose, and
        // creating them changes this list — switching away undid them.
        if (sink && String(sink.name || "").startsWith("praxis-")) return
        const best = _bestSink()
        if (best && best !== sink) setDefaultSink(best)
    }
    onSourcesChanged: {
        const best = _bestSource()
        if (best && best !== source) setDefaultSource(best)
    }
}

