import Foundation

extension AddCarbs {
    final class Provider: BaseProvider {
        @Injected() var apsManager: APSManager!
        
        var suggestion: Suggestion? {
            apsManager.suggestion
        }
    }
}