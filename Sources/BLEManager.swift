import CoreBluetooth

/// Connects to a Bosch GLM-family laser measure and forwards its raw packets.
/// The page decodes the packets, so the web and native versions share one parser.
final class BLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let serviceUUID = CBUUID(string: "02A6C0D0-0451-4000-B000-FB3210111989")
    private let characteristicUUID = CBUUID(string: "02A6C0D1-0451-4000-B000-FB3210111989")
    private let syncCommand = Data([0xC0, 0x55, 0x02, 0x01, 0x00, 0x1A]) // turn on measurement sync

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var wantsScan = false
    private var scanTimer: Timer?

    var onState: ((String, String) -> Void)?
    var onData: (([UInt8]) -> Void)?

    func connect() {
        wantsScan = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main) // prompts for Bluetooth the first time
        } else if central?.state == .poweredOn {
            startScan()
        }
    }

    func disconnect() {
        wantsScan = false
        scanTimer?.invalidate()
        central?.stopScan()
        if let p = peripheral {
            central?.cancelPeripheralConnection(p)
        } else {
            onState?("off", "Connect meter")
        }
    }

    private func startScan() {
        guard let central = central else { return }
        onState?("busy", "Searching…")
        central.scanForPeripherals(withServices: nil, options: nil)
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self = self, self.peripheral == nil else { return }
            self.central?.stopScan()
            self.wantsScan = false
            self.onState?("off", "No meter found")
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantsScan { startScan() }
        case .unauthorized:
            onState?("na", "Allow Bluetooth")
        case .poweredOff:
            onState?("na", "Bluetooth is off")
        case .unsupported:
            onState?("na", "No Bluetooth")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = ((advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "").uppercased()
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let isMeter = services.contains(serviceUUID) || name.hasPrefix("GLM") || name.hasPrefix("PLR")
            || name.contains("BOSCH") || name.hasPrefix("ZAMO")
        guard isMeter, self.peripheral == nil else { return }

        central.stopScan()
        scanTimer?.invalidate()
        self.peripheral = peripheral
        peripheral.delegate = self
        onState?("busy", "Connecting…")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        onState?("off", "Couldn't connect")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        onState?("off", "Reconnect")
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            onState?("off", "Meter not supported")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([characteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) else {
            onState?("off", "Meter not supported")
            return
        }
        peripheral.setNotifyValue(true, for: characteristic)
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(syncCommand, for: characteristic, type: type)
        onState?("on", String((peripheral.name ?? "Meter").prefix(16)))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        onData?([UInt8](value))
    }
}
