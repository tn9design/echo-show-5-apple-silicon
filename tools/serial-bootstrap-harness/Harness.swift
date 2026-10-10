import Darwin
import Foundation
public enum GuideError: Error, LocalizedError { case stopped(String); public var errorDescription: String? { switch self { case .stopped(let s): return s } } }
public struct OwnedSerialChannel: Sendable { public let vmID: UUID; public let portID: Int; public let path: String }
public struct GuestTrustEvidence: Sendable { public let ownedVMID: UUID; public let publicHostKey: String }
@main struct Harness {
 static func main() async {
  do {
   let args=Array(CommandLine.arguments.dropFirst())
   let owner=UUID(uuidString:"11111111-1111-4111-8111-111111111111")!
   let nonce=UUID(uuidString:"22222222-2222-4222-8222-222222222222")!
   let request=try GuestBootstrapRequest(ownedVMID:owner,nonce:nonce,username:"echotest")
   if args[0] == "emit" { print(GuestBootstrapProtocol.consoleCommand(for:request),terminator:"");return }
   if args[0] == "parse" {let data=FileHandle.standardInput.readDataToEndOfFile();_ = try GuestBootstrapProtocol.parse(String(decoding:data,as:UTF8.self),for:request); print("PARSED");return}
   let terminal=try SerialTransport(channel:.init(vmID:owner,portID:0,path:args[1]))
   FileHandle.standardError.write(Data("HARNESS-READY\n".utf8))
   do {
    try await SerialLogin.authenticate(terminal,password:"fixture-only",username:"echotest",promptTimeout:5)
    for _ in 0..<2 {
     try await terminal.write(Data(GuestBootstrapProtocol.consoleCommand(for:request).utf8))
     let bytes=try await terminal.read(until:Data(request.endMarker.utf8),timeout:5,limit:GuestBootstrapProtocol.maximumTranscriptBytes)
     if ProcessInfo.processInfo.environment["ECHOGUIDE_HARNESS_CAPTURE"] == "1" { print("TRANSCRIPT64 "+bytes.base64EncodedString()) }
     _ = try GuestBootstrapProtocol.parse(String(decoding:bytes,as:UTF8.self),for:request)
     print("PARSED")
    }
    await terminal.close()
   } catch {await terminal.close();throw error}
  } catch {FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)}
 }
}
