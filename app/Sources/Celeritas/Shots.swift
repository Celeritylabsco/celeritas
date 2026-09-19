import AppKit
import CeleritasKit
import SwiftUI

/// Put the app into one fixed state so a picture can be taken of it.
///
///     Celeritas.app/Contents/MacOS/Celeritas --demo coin
///
/// The pictures in the readme and the setup guide are taken from the real
/// windows, by `Scripts/make-shots.py`, which finds each window by id and
/// captures it alone. That keeps whatever is behind it off a public page: an
/// earlier full screen capture caught a desktop full of somebody's messages.
///
/// Rendering the views to an image instead would be neater and does not work.
/// `ImageRenderer` draws the text field as a yellow placeholder because it is
/// AppKit underneath, and the result rows do not lay out at all.
///
/// Every number here is made up, so nothing real is ever in a picture and the
/// same command a year from now produces the same image.
@MainActor
enum Shots {
    static let states = ["empty", "coin", "share", "currency", "units", "maths",
                         "convert", "token", "emoji", "apps", "machine",
                         "calendar", "answer"]

    static func machine() -> Machine {
        Machine(cpu: 16, memoryUsed: 19_004_297_216, memoryTotal: 34_359_738_368,
                diskFree: 397_284_147_200, diskTotal: 994_662_584_320,
                topCPU: [Usage(name: "WindowServer", value: "18.4%"),
                         Usage(name: "Safari", value: "9.1%"),
                         Usage(name: "Celeritas", value: "0.6%")],
                topMemory: [Usage(name: "Safari", value: "3.1 GB"),
                            Usage(name: "Xcode", value: "2.4 GB"),
                            Usage(name: "Music", value: "412 MB")])
    }

    static func fill(_ state: PaletteState, _ name: String) {
        state.machine = machine()
        guard name != "empty" else { return }

        func row(_ id: String, _ title: String, _ tag: String) -> Result {
            Result(id: id, kind: .conversion, title: title, tag: tag)
        }
        func ask(_ q: String) -> ResultSection {
            ResultSection(title: "Ask", results: [
                Result(id: "ask", kind: .ask, title: q, tag: "glm-5.3-flash")])
        }
        func set(_ query: String, _ sections: [ResultSection]) {
            state.query = query
            state.sections = sections + [ask(query)]
        }

        switch name {
        case "coin":
            set("btc", [ResultSection(title: "Markets", results: [
                row("m", "BTC  81,288.44 USD  +0.23%", "Bitcoin, live 14:07")])])
        case "share":
            set("aapl", [ResultSection(title: "Markets", results: [
                row("m", "AAPL  336.13  -0.26%", "Apple Inc., close 18 Sep")])])
        case "currency":
            set("100 usd in eur", [ResultSection(title: "Currency", results: [
                row("c", "92.04 EUR", "rate from 19 Sep")])])
        case "units":
            set("180 lb in kg", [ResultSection(title: "Conversion", results: [
                row("u", "81.65 kg", "180 lb  =  81.65 kg")])])
        case "maths":
            set("(1200 * 1.2) / 3", [ResultSection(title: "Calculator", results: [
                row("k", "480", "copy")])])
        case "convert":
            set("1 eth to sol", [ResultSection(title: "Markets", results: [
                row("s", "1 ETH  =  23.6044 SOL", "live 14:07")])])
        case "token":
            set("orbio price", [ResultSection(title: "Tokens", results: [
                row("t1", "ORBIO  $0.0528  +8.60%",
                    "Orbio.so on robinhood, $1.7m liquidity"),
                row("t2", "OIBRO  $0.0000198  -63.75%",
                    "Oibro on robinhood, $15k liquidity")])])
        case "emoji":
            set("fire", [ResultSection(title: "Emoji", results: [
                row("e1", "\u{1F525}   fire", "copy"),
                row("e2", "\u{1F692}   fire engine", "copy"),
                row("e3", "\u{1F9EF}   fire extinguisher", "copy"),
                row("e4", "\u{2764}\u{FE0F}\u{200D}\u{1F525}   heart on fire", "copy")])])
        case "apps":
            state.query = "act"
            state.sections = [
                ResultSection(title: "Applications", results: [
                    Result(id: "a1", kind: .app, title: "Activity Monitor",
                           tag: "Application",
                           iconPath: "/System/Applications/Utilities/Activity Monitor.app"),
                    Result(id: "a2", kind: .app, title: "Contacts", tag: "Application",
                           iconPath: "/System/Applications/Contacts.app")]),
                ask("act")]
        case "machine":
            set("battery", [ResultSection(title: "Actions", results: [
                Result(id: "b", kind: .action, title: "Battery and power",
                       tag: "System", tool: "battery_status")])])
        case "calendar":
            set("am i free tomorrow", [])
        case "answer":
            state.query = "remind me to renew the insurance on friday"
            state.outcome = .answered(
                "Reminder set for Friday.",
                PaletteState.Receipt(tool: "create_reminder",
                                     model: "glm-5.3-flash, via Orbio",
                                     seconds: 2.41, cost: 0.000183, instant: false))
        default:
            break
        }
    }
}
