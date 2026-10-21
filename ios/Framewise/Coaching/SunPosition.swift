import Foundation

/// Quality of the available daylight.
enum LightPhase: String, CaseIterable {
    case night
    case blueHour
    case goldenHour
    case softDaylight
    case harshDaylight
    /// No location permission, so we only know the clock.
    case unknown

    var displayName: String {
        switch self {
        case .night: return "Night"
        case .blueHour: return "Blue hour"
        case .goldenHour: return "Golden hour"
        case .softDaylight: return "Soft daylight"
        case .harshDaylight: return "Hard midday light"
        case .unknown: return "Daylight"
        }
    }

    var advice: String {
        switch self {
        case .night:
            return "Dark out. Look for pools of artificial light and brace the phone against something."
        case .blueHour:
            return "Deep blue sky, lights coming on. Balance a lit window against the sky."
        case .goldenHour:
            return "Low warm sun. Best light of the day — put it behind or beside your subject."
        case .softDaylight:
            return "Even, flattering light. Good for almost anything."
        case .harshDaylight:
            return "Hard overhead sun. Work in open shade, or use the harshness deliberately for graphic shadows."
        case .unknown:
            return "Light unknown — judge it by eye."
        }
    }
}

/// Where the sun is, and what that means for the light.
struct SunState {
    var elevationDegrees: Double
    var azimuthDegrees: Double
    var phase: LightPhase
    /// Time until the next golden-hour window opens, if it isn't open now.
    var timeToGoldenHour: TimeInterval?
    /// How long the current window has left, if we are in one.
    var goldenHourRemaining: TimeInterval?

    /// Compass direction the sun is in, as a word.
    var compassDirection: String {
        let points = ["north", "north-east", "east", "south-east",
                      "south", "south-west", "west", "north-west"]
        let index = Int((azimuthDegrees / 45).rounded()) % 8
        return points[(index + 8) % 8]
    }

    static var unknown: SunState {
        SunState(elevationDegrees: .nan,
                 azimuthDegrees: .nan,
                 phase: .unknown,
                 timeToGoldenHour: nil,
                 goldenHourRemaining: nil)
    }
}

/// Solar position from latitude, longitude and time.
///
/// Implements the standard NOAA approximation, which is accurate to well
/// under a degree — far better than we need to say "golden hour starts in
/// about forty minutes".
enum SunPosition {

    /// Solar elevation and azimuth in degrees. Azimuth is measured clockwise
    /// from true north.
    static func calculate(latitude: Double, longitude: Double, date: Date) -> (elevation: Double, azimuth: Double) {
        let julianDay = date.timeIntervalSince1970 / 86400.0 + 2440587.5
        let century = (julianDay - 2451545.0) / 36525.0

        // Mean elements of the Sun's apparent orbit.
        let meanLongitude = fmod(280.46646 + century * (36000.76983 + century * 0.0003032), 360)
        let meanAnomaly = 357.52911 + century * (35999.05029 - 0.0001537 * century)
        let eccentricity = 0.016708634 - century * (0.000042037 + 0.0000001267 * century)

        let anomalyRad = meanAnomaly * .pi / 180
        // Equation of the centre.
        let centreEquation = sin(anomalyRad) * (1.914602 - century * (0.004817 + 0.000014 * century))
            + sin(2 * anomalyRad) * (0.019993 - 0.000101 * century)
            + sin(3 * anomalyRad) * 0.000289

        let trueLongitude = meanLongitude + centreEquation
        // Correction for nutation and aberration.
        let apparentLongitude = trueLongitude
            - 0.00569
            - 0.00478 * sin((125.04 - 1934.136 * century) * .pi / 180)

        // Obliquity of the ecliptic.
        let meanObliquity = 23 + (26 + ((21.448 - century * (46.815 + century * (0.00059 - century * 0.001813)))) / 60) / 60
        let obliquity = meanObliquity + 0.00256 * cos((125.04 - 1934.136 * century) * .pi / 180)

        let declination = asin(sin(obliquity * .pi / 180) * sin(apparentLongitude * .pi / 180)) * 180 / .pi

        // Equation of time, in minutes.
        let varY = pow(tan(obliquity / 2 * .pi / 180), 2)
        let equationOfTime = 4 * (varY * sin(2 * meanLongitude * .pi / 180)
            - 2 * eccentricity * sin(anomalyRad)
            + 4 * eccentricity * varY * sin(anomalyRad) * cos(2 * meanLongitude * .pi / 180)
            - 0.5 * varY * varY * sin(4 * meanLongitude * .pi / 180)
            - 1.25 * eccentricity * eccentricity * sin(2 * anomalyRad)) * 180 / .pi

        // Fraction of the UTC day elapsed.
        let secondsIntoDay = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400)
        let minutesUTC = secondsIntoDay / 60

        // True solar time at this longitude, in minutes.
        var trueSolarTime = fmod(minutesUTC + equationOfTime + 4 * longitude, 1440)
        if trueSolarTime < 0 { trueSolarTime += 1440 }

        // Hour angle: zero at local solar noon.
        var hourAngle = trueSolarTime / 4 - 180
        if hourAngle < -180 { hourAngle += 360 }

        let latRad = latitude * .pi / 180
        let declRad = declination * .pi / 180
        let hourRad = hourAngle * .pi / 180

        let cosZenith = sin(latRad) * sin(declRad) + cos(latRad) * cos(declRad) * cos(hourRad)
        let zenith = acos(clampDouble(cosZenith, -1, 1))
        let elevation = 90 - zenith * 180 / .pi

        // Azimuth, measured clockwise from north.
        var azimuth: Double
        let denominator = cos(latRad) * sin(zenith)
        if abs(denominator) < 1e-8 {
            azimuth = latitude > 0 ? 180 : 0
        } else {
            let cosAzimuth = (sin(latRad) * cos(zenith) - sin(declRad)) / denominator
            azimuth = acos(clampDouble(cosAzimuth, -1, 1)) * 180 / .pi
            // acos loses the sign; before solar noon the sun is in the east.
            if hourAngle > 0 { azimuth = 360 - azimuth }
        }

        return (elevation, fmod(azimuth + 360, 360))
    }

    /// Full state including the phase and how long until the good light.
    static func state(latitude: Double, longitude: Double, date: Date = Date()) -> SunState {
        let now = calculate(latitude: latitude, longitude: longitude, date: date)
        let phase = classify(elevation: now.elevation)

        var timeToGolden: TimeInterval?
        var goldenRemaining: TimeInterval?

        // Walk forward in five-minute steps over the next 24 hours. Cheap
        // (288 evaluations) and avoids having to invert the solar equations.
        let step: TimeInterval = 300
        if phase == .goldenHour {
            var offset: TimeInterval = 0
            while offset < 86400 {
                offset += step
                let future = calculate(latitude: latitude, longitude: longitude,
                                       date: date.addingTimeInterval(offset))
                if classify(elevation: future.elevation) != .goldenHour {
                    goldenRemaining = offset
                    break
                }
            }
        } else {
            var offset: TimeInterval = 0
            while offset < 86400 {
                offset += step
                let future = calculate(latitude: latitude, longitude: longitude,
                                       date: date.addingTimeInterval(offset))
                if classify(elevation: future.elevation) == .goldenHour {
                    timeToGolden = offset
                    break
                }
            }
        }

        return SunState(elevationDegrees: now.elevation,
                        azimuthDegrees: now.azimuth,
                        phase: phase,
                        timeToGoldenHour: timeToGolden,
                        goldenHourRemaining: goldenRemaining)
    }

    /// Thresholds are the conventional photographic ones: golden hour runs
    /// from just below the horizon to about six degrees up, which is where the
    /// light stops being warm and directional.
    static func classify(elevation: Double) -> LightPhase {
        switch elevation {
        case ..<(-6): return .night
        case ..<(-1): return .blueHour
        case ..<6: return .goldenHour
        case ..<32: return .softDaylight
        default: return .harshDaylight
        }
    }

    /// Clock-only fallback when there is no location permission.
    static func approximatePhase(from date: Date, calendar: Calendar = .current) -> LightPhase {
        let hour = Double(calendar.component(.hour, from: date))
            + Double(calendar.component(.minute, from: date)) / 60
        switch hour {
        case ..<5.5: return .night
        case ..<6.5: return .blueHour
        case ..<8.0: return .goldenHour
        case ..<11.0: return .softDaylight
        case ..<16.0: return .harshDaylight
        case ..<18.5: return .softDaylight
        case ..<20.0: return .goldenHour
        case ..<21.0: return .blueHour
        default: return .night
        }
    }
}

private func clampDouble(_ value: Double, _ low: Double, _ high: Double) -> Double {
    min(max(value, low), high)
}
