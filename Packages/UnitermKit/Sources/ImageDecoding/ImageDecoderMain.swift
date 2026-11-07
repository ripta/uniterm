import Darwin
import Foundation
import ImageWire

/// The helper's entry point. The shipped helper and the unsandboxed test helper both call it from
/// a thin `main`.
public enum ImageDecoderMain {
  public static func run(arguments: [String]) -> Int32 {
    #if DEBUG
      if arguments.dropFirst().first == "--probe-sandbox" {
        return SandboxProbe.run(arguments: Array(arguments.dropFirst(2)))
      }
    #endif

    let socket = FramedSocket(descriptor: ImageProtocol.socketDescriptor)
    let server = ImageHelperServer(socket: socket)

    return server.run()
  }
}
