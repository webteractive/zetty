import Foundation
import QuerttyCore

// The standalone `quertty` executable — all logic lives in ControlCLI so the
// app binary (invoked via the installed symlink) shares it.
exit(ControlCLI.run(Array(CommandLine.arguments.dropFirst())))
