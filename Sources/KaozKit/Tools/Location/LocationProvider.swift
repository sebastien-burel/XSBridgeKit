import CoreLocation
import Foundation

/// Errors surfaced by the location tool to the model. Each maps to a clear
/// reason the user can act on (grant permission, reconnect, etc.).
enum LocationError: Error, LocalizedError, Equatable {
    case denied
    case restricted
    case unavailable(message: String)

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Accès à la localisation refusé. Autorisez TyKaoz dans Réglages système → Confidentialité → Localisation."
        case .restricted:
            return "Accès à la localisation restreint par la configuration de l'appareil."
        case .unavailable(let message):
            return "Localisation indisponible : \(message)"
        }
    }
}

/// Diagnostic signals observed while waiting for a fix. When the wait times
/// out, they turn a mute "no fix" into an actionable message. Pure value —
/// the message builder is unit-tested without CoreLocation.
struct LocationFixSignals: OptionSet, Sendable {
    let rawValue: Int

    /// The system reported it cannot determine the position — on a desktop
    /// Mac this almost always means Wi-Fi is off (no GPS; positioning scans
    /// nearby Wi-Fi networks).
    static let locationUnavailable = LocationFixSignals(rawValue: 1 << 0)
    /// The authorization prompt is still on screen.
    static let authorizationRequestInProgress = LocationFixSignals(rawValue: 1 << 1)
    /// The system considers the app not "in use" enough to serve it.
    static let insufficientlyInUse = LocationFixSignals(rawValue: 1 << 2)

    var timeoutMessage: String {
        if contains(.locationUnavailable) {
            return """
            le système ne peut pas déterminer la position. Sur un Mac de \
            bureau, la localisation nécessite le Wi-Fi activé (même sans \
            réseau connecté) — vérifie qu'il ne soit pas coupé.
            """
        }
        if contains(.authorizationRequestInProgress) {
            return "autorisation en attente — réponds à la demande de macOS puis réessaie."
        }
        if contains(.insufficientlyInUse) {
            return "macOS considère l'app inactive — mets TyKaoz au premier plan et réessaie."
        }
        return "aucun fix obtenu dans le délai imparti"
    }
}

/// Abstracts the underlying Core Location bits so the tool stays testable.
public protocol LocationProviding: Sendable {
    func currentLocation() async throws -> CLLocation
}

/// Uses `CLLocationUpdate.liveUpdates()` for the actual fix because the
/// delegate-based API was unreliable in practice: `requestLocation()` aborts
/// on the first transient `kCLErrorLocationUnknown`, and re-using
/// `startUpdatingLocation()` after a previous stop sometimes never re-delivers
/// an event. `CLServiceSession` would be the iOS path here; on macOS we still
/// drive authorization through `CLLocationManager`.
@MainActor
public final class AppleLocationProvider: NSObject, CLLocationManagerDelegate, LocationProviding {
    public static let shared = AppleLocationProvider()

    /// Cold Wi-Fi-based fixes can take longer than 15 s on macOS.
    private static let fixTimeout: Duration = .seconds(25)
    private static let cachedFixMaxAge: TimeInterval = 60

    private let manager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var lastFix: CLLocation?
    /// Diagnostic signals seen during the current fix attempt.
    private var signals: LocationFixSignals = []

    override init() {
        super.init()
        manager.delegate = self
    }

    public func currentLocation() async throws -> CLLocation {
        if let cached = lastFix,
           cached.horizontalAccuracy >= 0,
           -cached.timestamp.timeIntervalSinceNow <= Self.cachedFixMaxAge {
            return cached
        }

        // Global Location Services switch off → fail fast with the fix,
        // instead of a mute timeout. The API blocks, so query off-main.
        let servicesEnabled = await Task.detached {
            CLLocationManager.locationServicesEnabled()
        }.value
        guard servicesEnabled else {
            throw LocationError.unavailable(message: """
                le service de localisation est désactivé — active-le dans \
                Réglages système → Confidentialité et sécurité → Localisation.
                """)
        }

        let status = await ensureAuthorized()
        switch status {
        case .denied:     throw LocationError.denied
        case .restricted: throw LocationError.restricted
        default:          break
        }

        signals = []
        return try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask { @MainActor [weak self] in
                for try await update in CLLocationUpdate.liveUpdates() {
                    if update.authorizationDenied || update.authorizationDeniedGlobally {
                        throw LocationError.denied
                    }
                    if update.authorizationRestricted {
                        throw LocationError.restricted
                    }
                    // Record diagnostic hints so a timeout can explain itself.
                    if update.locationUnavailable {
                        self?.signals.insert(.locationUnavailable)
                    }
                    if update.authorizationRequestInProgress {
                        self?.signals.insert(.authorizationRequestInProgress)
                    }
                    if update.insufficientlyInUse {
                        self?.signals.insert(.insufficientlyInUse)
                    }
                    if let location = update.location,
                       location.horizontalAccuracy >= 0 {
                        self?.lastFix = location
                        return location
                    }
                }
                throw LocationError.unavailable(message: "flux interrompu sans fix")
            }
            group.addTask { @MainActor [weak self] in
                try await Task.sleep(for: Self.fixTimeout)
                // Last resort: the system's cached fix beats an error —
                // the tool flags its age to the model.
                if let cached = self?.manager.location,
                   cached.horizontalAccuracy >= 0 {
                    return cached
                }
                throw LocationError.unavailable(
                    message: self?.signals.timeoutMessage
                        ?? "aucun fix obtenu dans le délai imparti"
                )
            }

            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw LocationError.unavailable(message: "flux vide")
            }
            return first
        }
    }

    private func ensureAuthorized() async -> CLAuthorizationStatus {
        let current = manager.authorizationStatus
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard manager.authorizationStatus != .notDetermined,
                  let continuation = authorizationContinuation else { return }
            authorizationContinuation = nil
            continuation.resume(returning: manager.authorizationStatus)
        }
    }
}
