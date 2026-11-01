// qt-virtual-display [--name N] [--size WxH] — creates an invisible display for background screenshots and keeps it
// until killed (SIGTERM/SIGINT). It is placed diagonally off the bottom-right corner of the main display, so the
// pointer rarely wanders onto it. Prints the display id once ready. Dev tool; see Scripts/virtual-display.sh.
import AppKit
import CoreGraphics

var name = "QT Virtual"
var width: UInt32 = 1920, height: UInt32 = 1080
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--name": name = args.popFirst() ?? name
    case "--size":
        let p = (args.popFirst() ?? "").split(separator: "x").compactMap { UInt32($0) }
        if p.count == 2 { width = p[0]; height = p[1] }
    default: FileHandle.standardError.write("unknown argument \(a)\n".data(using: .utf8)!); exit(2)
    }
}

let descriptor = CGVirtualDisplayDescriptor()
descriptor.setDispatchQueue(DispatchQueue.main)
descriptor.name = name
descriptor.maxPixelsWide = width
descriptor.maxPixelsHigh = height
descriptor.sizeInMillimeters = CGSize(width: Double(width) * 0.28, height: Double(height) * 0.28)
descriptor.productID = 0x5154
descriptor.vendorID = 0x5154
descriptor.serialNum = 0x0001
descriptor.terminationHandler = { _, _ in }

guard let display = CGVirtualDisplay(descriptor: descriptor) else {
    FileHandle.standardError.write("could not create the virtual display\n".data(using: .utf8)!); exit(1)
}
let settings = CGVirtualDisplaySettings()
settings.hiDPI = 0
settings.modes = [CGVirtualDisplayMode(width: width, height: height, refreshRate: 60)]
guard display.apply(settings) else {
    FileHandle.standardError.write("could not apply the display mode\n".data(using: .utf8)!); exit(1)
}

// Corner placement: top-left of the virtual display at the main display's bottom-right corner.
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    let main = CGDisplayBounds(CGMainDisplayID())
    var config: CGDisplayConfigRef?
    if CGBeginDisplayConfiguration(&config) == .success {
        CGConfigureDisplayOrigin(config, display.displayID, Int32(main.maxX), Int32(main.maxY))
        CGCompleteDisplayConfiguration(config, .forSession)
    }
    print(display.displayID)
    fflush(stdout)
}

for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { exit(0) }
    src.resume()
    _ = Unmanaged.passRetained(src)
}
withExtendedLifetime(display) { RunLoop.main.run() }
