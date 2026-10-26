import Foundation
import IOKit.hid

// Siri Remote A2854 (VID 0x004C / PID 0x0315) HID 探测工具
// 用法：
//   swiftc -O Tools/remote-probe.swift -o build/remote-probe
//   ./build/remote-probe list     # 只枚举，不需要权限
//   ./build/remote-probe watch    # 实时打印按键，需要「输入监控」权限

let APPLE_VID = 0x004C
let A2854_PID = 0x0315

func openManager() -> IOHIDManager {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let match: [String: Any] = [
        kIOHIDVendorIDKey as String: APPLE_VID,
        kIOHIDProductIDKey as String: A2854_PID,
    ]
    IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
    let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    if r != kIOReturnSuccess {
        print("IOHIDManagerOpen 失败: 0x\(String(format: "%08X", r))")
    }
    return manager
}

func str(_ d: IOHIDDevice, _ key: String) -> String {
    (IOHIDDeviceGetProperty(d, key as CFString) as? String) ?? "-"
}

func int(_ d: IOHIDDevice, _ key: String) -> Int {
    (IOHIDDeviceGetProperty(d, key as CFString) as? Int) ?? 0
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "list"
let manager = openManager()

guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
    print("未找到 VID=0x004C PID=0x0315 的 HID 设备。")
    print("请确认：1) 遥控器已配对并连接  2) 按一下任意键唤醒遥控器")
    exit(1)
}

print("找到 \(devices.count) 个匹配设备：")
for d in devices {
    print("""
      ─────────────────────────────
      产品名   : \(str(d, kIOHIDProductKey))
      制造商   : \(str(d, kIOHIDManufacturerKey))
      传输     : \(str(d, kIOHIDTransportKey))
      VID/PID  : 0x\(String(format: "%04X", int(d, kIOHIDVendorIDKey)))/0x\(String(format: "%04X", int(d, kIOHIDProductIDKey)))
      PrimaryUsagePage/Usage: 0x\(String(format: "%X", int(d, kIOHIDPrimaryUsagePageKey)))/0x\(String(format: "%X", int(d, kIOHIDPrimaryUsageKey)))
      """)
    if let desc = IOHIDDeviceGetProperty(d, kIOHIDReportDescriptorKey as CFString) as? Data {
        print("      ReportDescriptor (\(desc.count) 字节): \(desc.map { String(format: "%02X", $0) }.joined(separator: " "))")
    }
}

if mode == "list" { exit(0) }

// ── watch 模式：实时打印按键 ──
print("\n开始监听按键，请按住遥控器上的键（Ctrl+C 退出）…\n")

var state: [String: Int] = [:]
let queue = DispatchQueue(label: "probe.hid")

let callback: IOHIDValueCallback = { context, result, sender, value in
    guard result == kIOReturnSuccess, let device = sender else { return }
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let v = IOHIDValueGetIntegerValue(value)

    // 只关心按键类，忽略触控坐标的连续抖动
    let interesting = (usagePage == 0x0C) || (usagePage == 0x09) || (usagePage == 0x07) || (usagePage == 0xFF00)
    guard interesting else { return }

    let key = "\(usagePage):\(usage)"
    let prev = state[key] ?? 0
    guard prev != v else { return }
    state[key] = v

    let edge = v > 0 ? "按下 ↓" : "松开 ↑"
    var name = ""
    if usagePage == 0x0C {
        let table: [UInt32: String] = [
            0x0040: "Menu/Back", 0x0041: "Menu/Back", 0x00CD: "PlayPause",
            0x00E9: "VolumeUp", 0x00EA: "VolumeDown", 0x00E2: "Mute",
            0x0067: "VolumeUp", 0x0068: "VolumeDown",
        ]
        name = " [\(table[usage] ?? "Consumer 0x\(String(usage, radix: 16))")]"
    }
    let ts = Date().timeIntervalSince1970
    print(String(format: "%.3f  usagePage=0x%X usage=0x%X value=%ld  %@%@",
                 ts, usagePage, usage, v, edge, name))
    _ = device
    fflush(stdout)
}

IOHIDManagerRegisterInputValueCallback(manager, callback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

DispatchQueue.global().asyncAfter(deadline: .now() + 60) { exit(0) }
CFRunLoopRun()
