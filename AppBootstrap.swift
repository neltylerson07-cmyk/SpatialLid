import Combine
import Cocoa
import Metal
import MetalKit
import ScreenCaptureKit
import IOKit.hid

@MainActor
final class AppBootstrap: ObservableObject {
    func runDiagnostics() async {
        print("--- Running Subsystem Diagnostics ---")
        
        // 1. Metal Verification
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            print("✓ Metal Device: \(metalDevice.name)")
            if metalDevice.makeDefaultLibrary() != nil {
                print("✓ Default Metal Library compiled successfully")
            } else {
                print("✗ Failed to load default Metal Library (Check Shaders.metal)")
            }
        } else {
            print("✗ No Metal-compatible GPU found")
        }

        // 2. IOHIDManager Verification
        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchingCriteria: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0x0020 // Sensor Page
        ]
        IOHIDManagerSetDeviceMatching(hidManager, matchingCriteria as CFDictionary)
        let openResult = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult == kIOReturnSuccess {
            print("✓ IOHIDManager initialized and open")
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        } else {
            print("✗ IOHIDManager failed to open with code: \(openResult)")
        }

        // 3. ScreenCaptureKit Verification
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            print("✓ ScreenCaptureKit active. Displays found: \(content.displays.count)")
        } catch {
            print("! ScreenCaptureKit note: Permission prompt required or user denied (\(error.localizedDescription))")
        }
    }
}
