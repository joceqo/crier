import Foundation
import CrierServer

// Headless daemon entry point. The real implementation lives in CrierServer
// so Crier.app can embed it (see Sources/CrierUI/main.swift).
do {
    try CrierServer.run()
} catch {
    FileHandle.standardError.write(Data("crier-daemon: bind failed: \(error)\n".utf8))
    exit(1)
}
