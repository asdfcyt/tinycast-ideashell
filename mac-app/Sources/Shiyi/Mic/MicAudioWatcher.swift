import Foundation
import CoreAudio

/// 监听「默认输入设备是否正在被使用」(系统的麦克风使用指示)。
/// 豆包等输入法真正开始/结束收音时,这个状态会同步变化,用来校准我们对录音状态的判断。
final class MicAudioWatcher {
    var onChange: ((Bool) -> Void)?
    private(set) var isRunning = false
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var runningBlock: AudioObjectPropertyListenerBlock?
    private var defaultBlock: AudioObjectPropertyListenerBlock?

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func start() {
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attachDefaultDevice() }
        defaultBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        attachDefaultDevice()
    }

    private func attachDefaultDevice() {
        detach()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        guard status == noErr, id != AudioObjectID(kAudioObjectUnknown) else {
            update(false)
            return
        }
        deviceID = id
        var runAddr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        runningBlock = block
        AudioObjectAddPropertyListenerBlock(id, &runAddr, DispatchQueue.main, block)
        refresh()
    }

    private func detach() {
        if deviceID != AudioObjectID(kAudioObjectUnknown), let block = runningBlock {
            var runAddr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(deviceID, &runAddr, DispatchQueue.main, block)
        }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        runningBlock = nil
    }

    private func refresh() {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { update(false); return }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value)
        update(status == noErr && value != 0)
    }

    private func update(_ running: Bool) {
        guard running != isRunning else { return }
        isRunning = running
        onChange?(running)
    }
}
