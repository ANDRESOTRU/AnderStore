//
//  AnderPackageCheck.swift
//  AnderStore
//
//  Looks inside an .ipa before it is installed, so an app that cannot possibly run is refused
//  with a reason instead of installed and then failing to start.
//
//  Deliberately narrow: it only rejects what is certain. 32-bit apps are NOT rejected —
//  AnderStore runs them through the emulator.
//

import Foundation
import UIKit

enum AnderPackageCheck {

    /// Returns a message to show the user, or nil when the app can be installed.
    static func problem(with appInfo: LCAppInfo, at folder: URL) -> String? {
        guard let plist = NSDictionary(contentsOf: folder.appendingPathComponent("Info.plist")) as? [String: Any] else {
            return nil
        }

        if let minimum = plist["MinimumOSVersion"] as? String,
           isVersion(minimum, newerThan: UIDevice.current.systemVersion) {
            return String(format: "lc.appList.needsNewerIOS".loc, minimum)
        }

        guard let executableName = plist["CFBundleExecutable"] as? String else { return nil }
        if isEncrypted(folder.appendingPathComponent(executableName)) {
            return "lc.appList.encryptedIpa".loc
        }

        return nil
    }

    // MARK: - Version

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Mach-O

    private static let fatMagic: UInt32 = 0xcafebabe
    private static let fatMagic64: UInt32 = 0xcafebabf
    private static let machMagic32: UInt32 = 0xfeedface
    private static let machMagic64: UInt32 = 0xfeedfacf
    private static let lcEncryptionInfo: UInt32 = 0x21
    private static let lcEncryptionInfo64: UInt32 = 0x2c

    /// true when any slice still carries FairPlay encryption (an App Store binary).
    static func isEncrypted(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 8 else {
            return false
        }

        guard let rawMagic = readUInt32(data, 0, swapped: false) else { return false }

        // Universal binary: check every slice.
        if rawMagic == fatMagic || rawMagic == fatMagic64 {
            guard let count = readUInt32(data, 4, swapped: true) else { return false }
            let entrySize = rawMagic == fatMagic64 ? 32 : 20
            for index in 0..<Int(min(count, 32)) {
                let entry = 8 + index * entrySize
                let offset: UInt64
                if rawMagic == fatMagic64 {
                    guard let high = readUInt32(data, entry + 8, swapped: true),
                          let low = readUInt32(data, entry + 12, swapped: true) else { return false }
                    offset = (UInt64(high) << 32) | UInt64(low)
                } else {
                    guard let value = readUInt32(data, entry + 8, swapped: true) else { return false }
                    offset = UInt64(value)
                }
                if sliceIsEncrypted(data, at: Int(offset)) { return true }
            }
            return false
        }

        return sliceIsEncrypted(data, at: 0)
    }

    private static func sliceIsEncrypted(_ data: Data, at start: Int) -> Bool {
        guard let magic = readUInt32(data, start, swapped: false) else { return false }
        let is64: Bool
        switch magic {
        case machMagic64: is64 = true
        case machMagic32: is64 = false
        default: return false
        }

        guard let commandCount = readUInt32(data, start + 16, swapped: false) else { return false }
        var offset = start + (is64 ? 32 : 28)

        for _ in 0..<Int(min(commandCount, 512)) {
            guard let command = readUInt32(data, offset, swapped: false),
                  let size = readUInt32(data, offset + 4, swapped: false),
                  size >= 8 else { return false }

            if command == lcEncryptionInfo || command == lcEncryptionInfo64 {
                if let cryptid = readUInt32(data, offset + 16, swapped: false), cryptid != 0 {
                    return true
                }
            }
            offset += Int(size)
            if offset >= data.count { return false }
        }
        return false
    }

    private static func readUInt32(_ data: Data, _ offset: Int, swapped: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { destination in
            data.copyBytes(to: destination, from: offset..<(offset + 4))
        }
        return swapped ? value.byteSwapped : value
    }
}
