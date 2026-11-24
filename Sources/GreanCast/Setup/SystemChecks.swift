// SystemChecks.swift
// Prerequisite checks for the setup assistant: Xcode, iPhone, Developer Mode, signing teams.

import Foundation

struct DeveloperTeam: Hashable, Identifiable {
    let id: String          // team ID, e.g. 5F78W6EN7K
    let name: String
    let isFree: Bool
    var label: String { "\(name) (\(id))\(isFree ? " — free, re-sign every 7 days" : "")" }
}

struct PhoneInfo: Hashable {
    let udid: String
    let name: String
    let osVersion: String
    let developerMode: Bool
    let transport: String   // "wired", "localNetwork"…
}

enum SystemChecks {

    /// Full Xcode (not just Command Line Tools) is required to run XCTest on a device.
    static func xcodeVersion() async -> String? {
        let sel = await Shell.run("/usr/bin/xcode-select", ["-p"])
        guard sel.ok, sel.output.contains(".app/Contents/Developer") else { return nil }
        let v = await Shell.xcrun(["xcodebuild", "-version"])
        guard v.ok else { return nil }
        return v.output.split(separator: "\n").first.map(String.init)
    }

    /// Teams of the Apple accounts added in Xcode › Settings › Accounts.
    static func teams() -> [DeveloperTeam] {
        guard let byAccount = CFPreferencesCopyAppValue("IDEProvisioningTeamByIdentifier" as CFString,
                                                         "com.apple.dt.Xcode" as CFString) as? [String: Any] else { return [] }
        var seen = Set<String>()
        var result: [DeveloperTeam] = []
        for case let list as [[String: Any]] in byAccount.values {
            for t in list {
                guard let id = t["teamID"] as? String, !seen.contains(id) else { continue }
                seen.insert(id)
                let free = (t["isFreeProvisioningTeam"] as? Bool) ?? ((t["isFreeProvisioningTeam"] as? NSNumber)?.boolValue ?? false)
                result.append(DeveloperTeam(id: id, name: t["teamName"] as? String ?? id, isFree: free))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// iPhones known to CoreDevice (`xcrun devicectl list devices`).
    static func phones() async -> [PhoneInfo] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("greancast-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = await Shell.xcrun(["devicectl", "list", "devices", "--json-output", tmp.path])
        guard r.ok, let data = try? Data(contentsOf: tmp),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { d in
            let props = d["deviceProperties"] as? [String: Any] ?? [:]
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            let conn = d["connectionProperties"] as? [String: Any] ?? [:]
            guard let udid = hw["udid"] as? String, (hw["platform"] as? String ?? "iOS") == "iOS",
                  (hw["reality"] as? String ?? "physical") == "physical" else { return nil }
            return PhoneInfo(udid: udid,
                             name: props["name"] as? String ?? "iPhone",
                             osVersion: props["osVersionNumber"] as? String ?? "?",
                             developerMode: (props["developerModeStatus"] as? String) == "enabled",
                             transport: conn["transportType"] as? String ?? "?")
        }
    }
}
