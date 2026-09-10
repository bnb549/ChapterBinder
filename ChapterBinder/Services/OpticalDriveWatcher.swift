import Foundation
import DiskArbitration
import IOKit

/// Watches DiskArbitration for audio CDs (IOCDMedia / CD_DA). USB SuperDrive
/// unplugs are treated as disc-disappeared events so a mid-rip abort can recover.
@Observable
final class OpticalDriveWatcher {
    var discs: [DetectedDisc] = []
    var hasOpticalHardware: Bool = false
    var lastError: String?
    var mockEnabled: Bool = false

    private var session: DASession?

    var audioDisc: DetectedDisc? { discs.first(where: \.isAudioCD) }

    func start() {
        refreshHardware()
        guard session == nil else { return }
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        let info = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            guard let context else { return }
            let watcher = Unmanaged<OpticalDriveWatcher>.fromOpaque(context).takeUnretainedValue()
            watcher.handle(disk: disk, appeared: true)
        }, info)

        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            guard let context else { return }
            let watcher = Unmanaged<OpticalDriveWatcher>.fromOpaque(context).takeUnretainedValue()
            watcher.handle(disk: disk, appeared: false)
        }, info)

        DASessionSetDispatchQueue(session, DispatchQueue.main)
        scanExisting()
    }

    func stop() {
        session = nil
    }

    func insertMock() {
        mockEnabled = true
        if !discs.contains(where: \.isMock) {
            discs.append(MockTOC.detected)
        }
    }

    func removeMock() {
        mockEnabled = false
        discs.removeAll { $0.isMock }
    }

    func refreshHardware() {
        hasOpticalHardware = detectOpticalHardware()
    }

    private func scanExisting() {
        scanVolumes()
    }

    private func scanVolumes() {
        let keys: [URLResourceKey] = [.volumeIsReadOnlyKey, .volumeLocalizedNameKey]
        guard let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return
        }
        for url in volumes {
            if url.lastPathComponent.localizedCaseInsensitiveContains("audio cd")
                || url.pathExtension.lowercased() == "cdda" {
                let id = url.path
                if !discs.contains(where: { $0.id == id }) {
                    discs.append(
                        DetectedDisc(
                            id: id,
                            name: url.lastPathComponent,
                            bsdName: url.lastPathComponent,
                            volumeURL: url,
                            isAudioCD: true,
                            toc: nil,
                            isMock: false
                        )
                    )
                }
            }
        }
    }

    private func handle(disk: DADisk, appeared: Bool) {
        let desc = DADiskCopyDescription(disk).map { $0 as NSDictionary }
        let bsd: String
        if let ptr = DADiskGetBSDName(disk) {
            bsd = String(cString: ptr)
        } else {
            bsd = UUID().uuidString
        }
        let content = (desc?[kDADiskDescriptionMediaContentKey] as? String) ?? ""
        let name = (desc?[kDADiskDescriptionVolumeNameKey] as? String)
            ?? (desc?[kDADiskDescriptionMediaNameKey] as? String)
            ?? "Audio CD"
        let isAudio = content == "CD_DA"
            || content.contains("CD_DA")
            || content.uppercased().contains("CDAUDIO")
            || name.localizedCaseInsensitiveContains("audio cd")

        let path = desc?[kDADiskDescriptionVolumePathKey] as? URL

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if appeared, isAudio {
                if !self.discs.contains(where: { $0.bsdName == bsd }) {
                    self.discs.append(
                        DetectedDisc(
                            id: bsd,
                            name: name,
                            bsdName: bsd,
                            volumeURL: path,
                            isAudioCD: true,
                            toc: nil,
                            isMock: false
                        )
                    )
                }
            } else if !appeared {
                self.discs.removeAll { $0.bsdName == bsd }
            }
            self.refreshHardware()
        }
    }

    private func detectOpticalHardware() -> Bool {
        var iterator: io_iterator_t = 0
        let classes = ["IOCDMedia", "IODVDMedia", "IOBDMedia", "IODVDServices"]
        for name in classes {
            let matching = IOServiceMatching(name)
            let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
            if kr == KERN_SUCCESS {
                let first = IOIteratorNext(iterator)
                IOObjectRelease(iterator)
                if first != 0 {
                    IOObjectRelease(first)
                    return true
                }
            }
        }
        return false
    }
}

