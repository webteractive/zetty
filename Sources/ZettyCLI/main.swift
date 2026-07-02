import Foundation
import ZettyCore

// The standalone `zetty` executable — all logic lives in ControlCLI so the
// app binary (invoked via the installed symlink) shares it.
exit(ControlCLI.run(Array(CommandLine.arguments.dropFirst())))
