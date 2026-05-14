import Foundation
import CoreBluetooth

/// Triggers the iOS Bluetooth permission prompt up front and ensures the
/// Bluetooth radio is powered before the DAT SDK touches it. The DAT SDK's
/// internal CBCentralManager logs `API MISUSE: ... not powered on` if the
/// user hasn't granted Bluetooth permission yet, so we own a manager early
/// just to trigger the prompt and warm the stack.
final class BluetoothPrimer: NSObject, CBCentralManagerDelegate {
    static let shared = BluetoothPrimer()
    private var manager: CBCentralManager?

    func prime() {
        guard manager == nil else { return }
        // Instantiating with a non-nil queue and showPowerAlert=true forces
        // the system to evaluate Bluetooth state and prompt for permission.
        manager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("[BT] CBCentralManager state=\(central.state.rawValue) authorization=\(CBManager.authorization.rawValue)")
    }
}
