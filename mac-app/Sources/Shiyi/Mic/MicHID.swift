import Foundation
import IOKit
import IOKit.hid

/// 通过 IOKit HID 与接收器通信(主线程 RunLoop 驱动,回调都在主线程)。
///
/// 接收器在系统里只有一个 HID 设备(USB 接口 0),同一个设备里带多个集合:
///  - 私有集合 0xFF90 (Report 0x55):配置/心跳(双击=静音位、单击=降噪位都通过这里观察)
///  - Consumer 0x000C (Report 0x06):三击会发送「音量+」(0x00E9,手机拍照快门键)
/// 所以只需要打开这一个设备:input report 回调解析心跳,input value 回调监听三击。
/// 默认以共享方式打开(不占住整个接口,插在拓展坞上也不会和别的设备抢);
/// [exclusive] 打开时才尝试独占(三击不会同时把系统音量调大),被别的软件占用时退回共享方式。
final class MicHIDLink {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onPacket: ((UInt8, UInt8, [UInt8]) -> Void)?
    /// Consumer 集合上的按键:参数为 usage、是否按下。
    var onConsumerKey: ((Int, Bool) -> Void)?

    private(set) var openStatus: IOReturn = kIOReturnSuccess
    private(set) var isAttached = false
    private(set) var consumerSeized = false
    /// 是否优先独占打开;改了之后要 stop() + start() 才生效
    var exclusive = false
    /// HID 管理器是否已成功打开(没打开就要重试,否则永远收不到设备)
    var isOpen: Bool { manager != nil }
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)

    deinit { inputBuffer.deallocate() }

    func start() {
        guard manager == nil else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: MicProto.vid,
            kIOHIDProductIDKey as String: MicProto.pid,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<MicHIDLink>.fromOpaque(ctx).takeUnretainedValue().attached(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<MicHIDLink>.fromOpaque(ctx).takeUnretainedValue().detached(dev)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        var status: IOReturn
        consumerSeized = false
        if exclusive {
            // 独占失败(被其它程序占用)再退回共享
            status = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            if status == kIOReturnSuccess {
                consumerSeized = true
            } else {
                status = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            }
        } else {
            status = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        openStatus = status
        guard status == kIOReturnSuccess else {
            // 没打开成功:不留半开的管理器,让上层定时重试
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return
        }
        manager = mgr
    }

    /// 回调漏掉时的兜底:管理器已打开、系统里也有这个设备,但没收到「设备到位」回调(拓展坞枚举慢时会这样)
    func rescan() {
        guard let mgr = manager, device == nil,
              let found = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let dev = found.first else { return }
        attached(dev)
    }

    func stop() {
        if let mgr = manager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        device = nil
        consumerSeized = false
        isAttached = false
    }

    private func attached(_ dev: IOHIDDevice) {
        device = dev
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, inputBuffer, 512, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            let link = Unmanaged<MicHIDLink>.fromOpaque(ctx).takeUnretainedValue()
            if let (cmd, dev, payload) = MicProto.parse(bytes) { link.onPacket?(cmd, dev, payload) }
        }, ctx)
        IOHIDDeviceRegisterInputValueCallback(dev, { ctx, _, _, value in
            guard let ctx else { return }
            let el = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(el)
            guard page == 0x0C else { return }
            let usage = Int(IOHIDElementGetUsage(el))
            let down = IOHIDValueGetIntegerValue(value) != 0
            Unmanaged<MicHIDLink>.fromOpaque(ctx).takeUnretainedValue().onConsumerKey?(usage, down)
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        isAttached = true
        onConnect?()
    }

    private func detached(_ dev: IOHIDDevice) {
        guard let d = device, CFEqual(d, dev) else { return }
        device = nil
        isAttached = false
        onDisconnect?()
    }

    @discardableResult
    func send(cmd: UInt8, payload: [UInt8] = [], dev target: UInt8 = MicProto.devRX) -> Bool {
        guard let dev = device else { return false }
        let pkt = MicProto.packet(cmd: cmd, payload: payload, dev: target)
        let r = pkt.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(MicProto.reportID), $0.baseAddress!, pkt.count)
        }
        return r == kIOReturnSuccess
    }
}
