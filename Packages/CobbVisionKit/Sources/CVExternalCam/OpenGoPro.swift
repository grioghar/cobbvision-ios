import Foundation
import CVCore

/// Open GoPro BLE protocol constants and command encoding (public spec:
/// https://gopro.github.io/OpenGoPro/ble/). Pure data so the encodings are
/// golden-tested on any host; `GoProController` does the CoreBluetooth I/O.
public enum OpenGoPro {
    /// GoPro cameras advertise this 16-bit service UUID.
    public static let advertisedServiceUUID = "FEA6"

    /// Control & Query service and characteristics (128-bit).
    public enum GATT {
        public static let controlService = "0000FEA6-0000-1000-8000-00805F9B34FB"
        public static let commandCharacteristic = "B5F90072-AA8D-11E3-9046-0002A5D5C51B"
        public static let commandResponseCharacteristic = "B5F90073-AA8D-11E3-9046-0002A5D5C51B"
        public static let settingsCharacteristic = "B5F90074-AA8D-11E3-9046-0002A5D5C51B"
        public static let settingsResponseCharacteristic = "B5F90075-AA8D-11E3-9046-0002A5D5C51B"
        public static let queryCharacteristic = "B5F90076-AA8D-11E3-9046-0002A5D5C51B"
        public static let queryResponseCharacteristic = "B5F90077-AA8D-11E3-9046-0002A5D5C51B"

        /// WiFi Access Point service: read the camera's AP SSID/password to
        /// join it with NEHotspotConfiguration (HTTP API at 10.5.5.9:8080).
        public static let wifiService = "B5F90001-AA8D-11E3-9046-0002A5D5C51B"
        public static let wifiSSIDCharacteristic = "B5F90002-AA8D-11E3-9046-0002A5D5C51B"
        public static let wifiPasswordCharacteristic = "B5F90003-AA8D-11E3-9046-0002A5D5C51B"
    }

    /// TLV command packets written to the Command characteristic.
    /// Layout: [length, command id, params…].
    public enum Command {
        public static let shutterOn = Data([0x03, 0x01, 0x01, 0x01])
        public static let shutterOff = Data([0x03, 0x01, 0x01, 0x00])
        public static let sleep = Data([0x01, 0x05])
        public static let enableWiFiAP = Data([0x03, 0x17, 0x01, 0x01])
        public static let disableWiFiAP = Data([0x03, 0x17, 0x01, 0x00])

        /// Load preset group (command 0x3E, big-endian UInt16 group id):
        /// 1000 video, 1001 photo, 1002 timelapse.
        public static func loadPresetGroup(_ mode: ExternalCamMode) -> Data {
            let groupID: UInt16 = switch mode {
            case .video: 1000
            case .photo: 1001
            case .timelapse: 1002
            }
            return Data([0x04, 0x3E, 0x02, UInt8(groupID >> 8), UInt8(groupID & 0xFF)])
        }
    }

    /// Keep-alive: write setting 91 = 66 every ~3 s or the camera drops BLE.
    public enum Setting {
        public static let keepAlive = Data([0x03, 0x5B, 0x01, 0x42])
    }

    /// Command responses arrive on the response characteristic as
    /// [length, command id, status, …]; status 0 = success.
    public static func parseCommandResponse(_ data: Data) -> (commandID: UInt8, success: Bool)? {
        guard data.count >= 3 else { return nil }
        let bytes = [UInt8](data)
        return (commandID: bytes[1], success: bytes[2] == 0x00)
    }
}
