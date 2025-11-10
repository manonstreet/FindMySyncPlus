import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class LoginItemManager: ObservableObject {
    @Published var isEnabled: Bool = false
    @AppStorage("loginItemEnabledCache") private var isEnabledCache: Bool = false
    
    init() {
        self.isEnabled = isEnabledCache
        Task {
            let systemStatusIsEnabled = SMAppService.mainApp.status == .enabled
            if self.isEnabled != systemStatusIsEnabled {
                // If the cache is out of sync, update both the UI state and the cache.
                self.isEnabled = systemStatusIsEnabled
                self.isEnabledCache = systemStatusIsEnabled
            }
        }
    }

    func setLoginItem(enabled: Bool, logger: LogStore?) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            
            let newStatus = SMAppService.mainApp.status == .enabled
            self.isEnabled = newStatus
            self.isEnabledCache = newStatus
            logger?.info("Run FindMySync+ on user login set to: \(self.isEnabled)")
        } catch {
            self.isEnabled = SMAppService.mainApp.status == .enabled
            self.isEnabledCache = self.isEnabled
            logger?.error("Failed to update login item status: \(error.localizedDescription)")
        }
    }
}
