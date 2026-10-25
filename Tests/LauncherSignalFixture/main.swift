import Darwin

// This executable is compiled separately from XCTest. Its signal disposition
// and standard descriptors can therefore be changed without affecting a runner.
// It creates only local pipes/socketpairs supplied by the parent test harness.
let arguments = Array(CommandLine.arguments.dropFirst())
_ = Darwin.signal(SIGPIPE, SIG_DFL)

guard arguments.first == "--cli" || arguments.first == "--gui" else { Darwin._exit(64) }
let gui = arguments[0] == "--gui"
var options = [String: String]()
var index = 1
while index < arguments.count {
    guard index + 1 < arguments.count, options[arguments[index]] == nil else { Darwin._exit(64) }
    options[arguments[index]] = arguments[index + 1]
    index += 2
}
guard let target = options["--target"],
      ["stdout", "stderr", "socket", "healthy", "idle"].contains(target),
      options.keys.allSatisfy({ ["--target", "--result-fd", "--ready-fd", "--go-fd"].contains($0) }) else {
    Darwin._exit(64)
}
if gui && !GUIProcessSignals.configure() { Darwin._exit(65) }

func descriptor(_ name: String) -> Int32? {
    guard let value = options[name], let number = Int32(value), number >= 3 else { return nil }
    return number
}

@discardableResult
func writeText(_ text: String, to descriptor: Int32) -> (count: Int, error: Int32) {
    let bytes = Array(text.utf8)
    let count = bytes.withUnsafeBufferPointer { buffer in
        Darwin.write(descriptor, buffer.baseAddress, buffer.count)
    }
    let error = errno
    return (count, error)
}

// Tell the parent that this child has installed its selected signal policy,
// then wait until the parent has disconnected a previously healthy pipe.
if let ready = descriptor("--ready-fd") {
    guard writeText("R", to: ready).count == 1 else { Darwin._exit(66) }
    Darwin.close(ready)
}
if let go = descriptor("--go-fd") {
    var byte: UInt8 = 0
    guard Darwin.read(go, &byte, 1) == 1, byte == UInt8(ascii: "G") else { Darwin._exit(67) }
    Darwin.close(go)
}

if target == "healthy" {
    let stdout = "fixture stdout\n"
    let stderr = "fixture stderr\n"
    guard writeText(stdout, to: STDOUT_FILENO).count == stdout.utf8.count,
          writeText(stderr, to: STDERR_FILENO).count == stderr.utf8.count else { Darwin._exit(68) }
    Darwin._exit(0)
}
if target == "idle" {
    while true { _ = Darwin.pause() }
}

let result: (count: Int, error: Int32)
switch target {
case "stdout": result = writeText("disconnected stdout\n", to: STDOUT_FILENO)
case "stderr": result = writeText("disconnected stderr\n", to: STDERR_FILENO)
case "socket":
    var pair = [Int32](repeating: -1, count: 2)
    let status = pair.withUnsafeMutableBufferPointer {
        Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress)
    }
    guard status == 0 else { Darwin._exit(69) }
    Darwin.close(pair[1])
    result = writeText("disconnected socket\n", to: pair[0])
    Darwin.close(pair[0])
default: Darwin._exit(64)
}

// An unprotected child must have already died of SIGPIPE. A protected GUI must
// receive precisely EPIPE, and it reports that through an independent live fd.
guard gui, result.count == -1, result.error == EPIPE,
      let output = descriptor("--result-fd"),
      writeText("EPIPE\n", to: output).count == 6 else { Darwin._exit(70) }
Darwin.close(output)
Darwin._exit(0)
