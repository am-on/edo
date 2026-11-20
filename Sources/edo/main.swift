import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "detect", "plan", "render", "levels":
    Task { @MainActor in
        do {
            try await CLI.run(arguments)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("edo: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
case "-h", "--help", "help":
    print(CLI.usage)
default:
    // AppKit skips the editor window when launched with extra arguments, so Edo restarts itself
    // without them and passes the video along in EDO_OPEN.
    if !arguments.isEmpty, let program = Bundle.main.executablePath {
        if let path = arguments.first, FileManager.default.fileExists(atPath: path) {
            setenv("EDO_OPEN", URL(fileURLWithPath: path).standardizedFileURL.path, 1)
        }
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(program), nil]
        execv(program, argv)
    }
    if let path = ProcessInfo.processInfo.environment["EDO_OPEN"] {
        Launch.url = URL(fileURLWithPath: path)
        unsetenv("EDO_OPEN")
    }
    Snapshot.log("launching")
    EdoApp.main()
}
