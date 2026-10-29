// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ContentKit

// Length-prefixed UTF-16 preserves store command lines without passing them through cmd.exe.
public enum GOGLaunchManifest {
    public static func make(executable: String, arguments: String, dependencies: [GOGDependency],
                            support: [GOGSupportCommand], build: String, workingDirectory: String = "") throws -> Data {
        var commands: [(String, String, String)] = []
        func relative(_ value: String) throws -> String {
            let normalized = try SafePath.normalize(value)
            var seen = Set<String>()
            try WindowsName.check(path: normalized.split(separator: "/").map(String.init), seen: &seen)
            return normalized.replacingOccurrences(of: "/", with: "\\")
        }
        func marker(_ id: String) -> String {
            ".madeira-" + String((id + "-" + build).map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }) + ".done"
        }
        for dep in dependencies where !dep.executable.isEmpty {
            let path = try relative(dep.executable)
            if dep.isWindowsInstallerPackage {
                commands.append(("C:\\windows\\system32\\msiexec.exe", "/i \"\(path)\" " + dep.arguments, marker(dep.id)))
            } else if dep.isProgram {
                commands.append((path, dep.arguments, marker(dep.id)))
            } else { throw ClientError.unsafeContent("unsupported GOG dependency installer") }
        }
        for command in support { commands.append((try relative(command.executable), "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART", marker(command.productID))) }
        commands.append((try relative(executable), arguments, ""))
        guard commands.count <= 128 else { throw ClientError.unsafeContent("too many GOG launch commands") }
        var data = Data()
        func number(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        number(UInt32(commands.count))
        for command in commands {
            let directory = command.2.isEmpty && !workingDirectory.isEmpty ? try relative(workingDirectory) : ""
            for value in [command.0, command.1, command.2, directory] {
                let units = Array(value.utf16)
                guard units.count < 32767, !units.contains(0) else { throw ClientError.unsafeContent("invalid GOG launch command") }
                number(UInt32(units.count + 1))
                for unit in units + [0] { var little = unit.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
            }
        }
        return data
    }
}
