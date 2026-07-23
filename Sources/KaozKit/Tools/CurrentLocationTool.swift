import CoreLocation
import Contacts
import Foundation
import MapKit

/// Returns the device's current geographic position and, by default, the
/// reverse-geocoded postal address. Uses Apple's Core Location framework for
/// the fix and MapKit's `MKReverseGeocodingRequest` for the address — no
/// network call beyond Apple's services. The user is prompted for permission
/// the first time the tool runs.
public struct CurrentLocationTool: Tool {
    public let provider: any LocationProviding

    public init(provider: any LocationProviding = AppleLocationProvider.shared) {
        self.provider = provider
    }

    public let spec = ToolSpec(
        name: "current_location",
        description: """
        Returns the user's current latitude and longitude, plus the postal
        address (when include_address is true, the default). Use when the user
        asks "where am I", or when a task needs to be tailored to where they
        are. macOS will prompt for permission on first use.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "include_address": {
              "type": "boolean",
              "description": "Resolve the coordinates to a postal address (default true)."
            }
          },
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable {
        let includeAddress: Bool?

        enum CodingKeys: String, CodingKey {
            case includeAddress = "include_address"
        }
    }

    public func execute(arguments: Data) async throws -> String {
        let args = (try? JSONDecoder().decode(Args.self, from: arguments))
            ?? Args(includeAddress: nil)

        let location: CLLocation
        do {
            location = try await provider.currentLocation()
        } catch let toolError as LocationError {
            throw ToolError.execution(message: toolError.errorDescription ?? "Localisation impossible")
        } catch {
            throw ToolError.execution(message: error.localizedDescription)
        }

        var lines = [
            "Latitude : \(formatted(location.coordinate.latitude))",
            "Longitude : \(formatted(location.coordinate.longitude))"
        ]
        if location.horizontalAccuracy >= 0 {
            lines.append("Précision : ±\(Int(location.horizontalAccuracy.rounded())) m")
        }
        // A stale fix (the provider's last-known-position fallback) is
        // flagged so the model can qualify its answer.
        let age = -location.timestamp.timeIntervalSinceNow
        if age > Self.staleFixAge {
            lines.append("Attention : fix obtenu il y a \(Int(age / 60)) min — position possiblement ancienne.")
        }

        if args.includeAddress ?? true,
           let address = try? await reverseGeocode(location) {
            lines.append("Adresse : \(address)")
        }
        return lines.joined(separator: "\n")
    }

    /// Beyond this, the fix is old enough to caveat (fallback path).
    public static let staleFixAge: TimeInterval = 300

    private func formatted(_ degrees: CLLocationDegrees) -> String {
        String(format: "%.5f", degrees)
    }

    /// macOS 26 replaces CLGeocoder with MapKit's `MKReverseGeocodingRequest`;
    /// `MKAddressRepresentations.fullAddress` renders the result in the user's
    /// locale conventions on a single line.
    private func reverseGeocode(_ location: CLLocation) async throws -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let items = try await request.mapItems
        return items.first?
            .addressRepresentations?
            .fullAddress(includingRegion: true, singleLine: true)
    }
}
