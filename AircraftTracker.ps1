<#
.SYNOPSIS
    PowerShell Aircraft Tracker using the OpenSky Network API.

.DESCRIPTION
    This script fetches and displays aircraft data from the OpenSky Network API
    for a specified location. It can determine your location automatically using
    IP geolocation or accept manual coordinates.

.PARAMETER Radius
    The radius in degrees to search for aircraft (default: 0.1, approximately 11km).
    This is converted to kilometers internally for more accurate calculations.

.PARAMETER OutputHTML
    Switch to output results as HTML instead of console text.
    The HTML file will be saved as aircraft_data.html in the current directory.

.PARAMETER Latitude
    Manually specified latitude coordinate.

.PARAMETER Longitude
    Manually specified longitude coordinate.

.PARAMETER NoCache
    Switch to disable caching of API responses.

.PARAMETER CacheMinutes
    How long to cache results in minutes (default: 2).

.NOTES
    Author: Viorel-Felix Ciucu
    Version: 1.1.0
    OpenSky API Documentation: https://openskynetwork.github.io/opensky-api/rest.html

    Rate Limits for Anonymous Users:
    - Maximum 400 requests per day
    - Maximum 4 requests per minute

.EXAMPLE
    .\AircraftTracker.ps1
    Runs the tracker using IP geolocation to determine your location.

.EXAMPLE
    .\AircraftTracker.ps1 -Latitude 48.8566 -Longitude 2.3522
    Runs the tracker for the specified coordinates (Paris).

.EXAMPLE
    .\AircraftTracker.ps1 -Radius 0.2 -OutputHTML
    Runs the tracker with a larger radius and outputs results as HTML.
#>

[CmdletBinding()]
param(
    [Parameter(HelpMessage="Bounding box radius in degrees (default: 0.1, ~11km)")]
    [ValidateRange(0.01, 5)]
    [double]$Radius = 0.1,

    [Parameter(HelpMessage="Output HTML instead of console text")]
    [switch]$OutputHTML,

    [Parameter(HelpMessage="Manually specified latitude")]
    [ValidateRange(-90, 90)]
    [double]$Latitude,

    [Parameter(HelpMessage="Manually specified longitude")]
    [ValidateRange(-180, 180)]
    [double]$Longitude,

    [Parameter(HelpMessage="Disable caching of API responses")]
    [switch]$NoCache,

    [Parameter(HelpMessage="How long to cache results in minutes")]
    [ValidateRange(1, 60)]
    [int]$CacheMinutes = 2
)

# Script variables
$script:CacheFile = Join-Path $env:TEMP "OpenSkyCache.xml"
$script:CacheExpiry = [DateTime]::MinValue

function Get-LocationFromIP {
    # Try multiple geolocation services in case one fails
    $geoServices = @(
        @{
            Name = "ip-api.com"
            Uri = "http://ip-api.com/json/"
            LatPath = "lat"
            LonPath = "lon"
        },
        @{
            Name = "ipinfo.io"
            Uri = "https://ipinfo.io/json"
            LatPath = "loc"
            LonPath = "loc"
            PostProcess = {
                param($value)
                if ($value -match "^([-\d.]+),([-\d.]+)$") {
                    return @{
                        Latitude = [double]$Matches[1]
                        Longitude = [double]$Matches[2]
                    }
                }
                return $null
            }
        }
    )

    foreach ($service in $geoServices) {
        try {
            Write-Host "Getting location from $($service.Name)..." -ForegroundColor Yellow
            $geoResponse = Invoke-RestMethod -Uri $service.Uri -TimeoutSec 10

            # Handle special post-processing if needed
            if ($service.PostProcess) {
                $processed = & $service.PostProcess $geoResponse.($service.LatPath)
                if ($processed) {
                    return @{
                        Latitude = $processed.Latitude
                        Longitude = $processed.Longitude
                        Method = "$($service.Name) Geolocation"
                    }
                }
            }
            else {
                # Standard processing
                return @{
                    Latitude = $geoResponse.($service.LatPath)
                    Longitude = $geoResponse.($service.LonPath)
                    Method = "$($service.Name) Geolocation"
                }
            }
        }
        catch {
            Write-Warning "Failed to get location from $($service.Name): $_"
            # Continue to next service
        }
    }

    Write-Error "All geolocation services failed."
    return $null
}

function Convert-DegreesToRadians {
    param([double]$Degrees)
    return $Degrees * [Math]::PI / 180
}

function Convert-RadiansToDegrees {
    param([double]$Radians)
    return $Radians * 180 / [Math]::PI
}

function Get-BoundingBox {
    param(
        [double]$Latitude,
        [double]$Longitude,
        [double]$RadiusKm = 11 # Default ~11km (equivalent to 0.1 degrees at equator)
    )

    # Earth's radius in kilometers
    $earthRadius = 6371.0

    # Convert latitude and longitude to radians
    $latRad = Convert-DegreesToRadians -Degrees $Latitude
    $lonRad = Convert-DegreesToRadians -Degrees $Longitude

    # Angular distance in radians on a great circle
    $angularDistance = $RadiusKm / $earthRadius

    # Calculate min/max latitudes
    $latMinRad = $latRad - $angularDistance
    $latMaxRad = $latRad + $angularDistance

    # Calculate min/max longitudes
    $deltaLon = [Math]::Asin([Math]::Sin($angularDistance) / [Math]::Cos($latRad))
    $lonMinRad = $lonRad - $deltaLon
    $lonMaxRad = $lonRad + $deltaLon

    # Convert back to degrees
    $result = @{
        LatMin = Convert-RadiansToDegrees -Radians $latMinRad
        LatMax = Convert-RadiansToDegrees -Radians $latMaxRad
        LonMin = Convert-RadiansToDegrees -Radians $lonMinRad
        LonMax = Convert-RadiansToDegrees -Radians $lonMaxRad
    }

    return $result
}

function Get-AircraftData {
    param(
        [double]$Latitude,
        [double]$Longitude,
        [double]$Radius
    )

    # Calculate bounding box (convert degrees to km - approx 111km per degree at equator)
    $radiusKm = $Radius * 111
    $boundingBox = Get-BoundingBox -Latitude $Latitude -Longitude $Longitude -RadiusKm $radiusKm

    $latMin = $boundingBox.LatMin
    $latMax = $boundingBox.LatMax
    $lonMin = $boundingBox.LonMin
    $lonMax = $boundingBox.LonMax

    # Build OpenSky API URL
    $url = "https://opensky-network.org/api/states/all?lamin=$latMin&lomin=$lonMin&lamax=$latMax&lomax=$lonMax"

    Write-Host "Fetching aircraft data..." -ForegroundColor Yellow
    Write-Host "API URL: $url" -ForegroundColor Gray

    try {
        # Add retry logic with exponential backoff for rate limiting
        $maxRetries = 3
        $retryCount = 0
        $delaySec = 2

        while ($retryCount -lt $maxRetries) {
            try {
                $response = Invoke-RestMethod -Uri $url -TimeoutSec 30

                # Validate response data
                if ($null -eq $response) {
                    throw "API returned null response"
                }

                # Check if the response has the expected properties
                if (-not (Get-Member -InputObject $response -Name "states" -MemberType Properties)) {
                    Write-Warning "API response does not contain 'states' property. This may indicate a change in the API format."
                    Write-Verbose "Response: $($response | ConvertTo-Json -Depth 1)"

                    # Try to handle the case where the API might return an error message
                    if ((Get-Member -InputObject $response -Name "error" -MemberType Properties)) {
                        throw "API returned error: $($response.error)"
                    }

                    # Create a compatible response structure
                    $compatibleResponse = [PSCustomObject]@{
                        states = @()
                        time = Get-Date
                    }
                    return $compatibleResponse
                }

                # Ensure states is not null
                if ($null -eq $response.states) {
                    Write-Warning "API response contains null 'states' property. Creating empty array."
                    $response.states = @()
                }

                return $response
            }
            catch [System.Net.WebException] {
                $statusCode = [int]$_.Exception.Response.StatusCode

                # Check if rate limited (429) or server error (5xx)
                if ($statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -lt 600)) {
                    $retryCount++
                    if ($retryCount -lt $maxRetries) {
                        Write-Warning "Request failed with status $statusCode. Retrying in $delaySec seconds... (Attempt $retryCount of $maxRetries)"
                        Start-Sleep -Seconds $delaySec
                        # Exponential backoff
                        $delaySec = $delaySec * 2
                    }
                    else {
                        throw
                    }
                }
                else {
                    throw
                }
            }
        }
    }
    catch {
        Write-Error "Failed to fetch aircraft data: $_"
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 429) {
            Write-Warning "OpenSky API rate limit reached. Anonymous users are limited to 4 requests per minute and 400 requests per day."
        }

        # Return empty response instead of null to prevent errors
        return [PSCustomObject]@{
            states = @()
            time = Get-Date
        }
    }
}

function Format-AircraftConsole {
    param($AircraftData, $Location)

    $states = $AircraftData.states
    $statesCount = if ($states) { $states.Count } else { 0 }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    Write-Host ""
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host "NEARBY AIRCRAFT TRACKER" -ForegroundColor Cyan
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host "Location: $($Location.Latitude), $($Location.Longitude) ($($Location.Method))" -ForegroundColor Gray
    Write-Host "Time: $timestamp" -ForegroundColor Gray
    Write-Host ""
    Write-Host " AIRCRAFT NEARBY: $statesCount " -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host ""

    if ($statesCount -gt 0) {
        $plane = $states[0]

        # Extract data from the array (OpenSky API returns arrays)
        # See API documentation for field meanings:
        # 0: icao24 - Unique ICAO 24-bit address of the transponder
        # 1: callsign - Callsign of the vehicle (can be null)
        # 2: origin_country - Country name inferred from the ICAO address
        # 7: baro_altitude - Barometric altitude in meters (can be null)
        # 8: on_ground - Boolean indicating if the position was from a surface position report
        # 9: velocity - Velocity over ground in m/s (can be null)
        # 10: true_track - True track in decimal degrees clockwise from north (can be null)
        # 11: vertical_rate - Vertical rate in m/s (can be null)

        $icao24 = $plane[0]
        $callsign = if ($null -ne $plane[1]) { $plane[1].Trim() } else { "" }
        $originCountry = if ($null -ne $plane[2]) { $plane[2].Trim() } else { "" }
        $baroAltitude = $plane[7]  # Can be null
        $onGround = $plane[8]
        $velocity = $plane[9]  # Can be null

        # Display primary aircraft info
        Write-Host "FEATURED AIRCRAFT:" -ForegroundColor Yellow
        Write-Host "├─ CALLSIGN: " -NoNewline -ForegroundColor Gray
        if ($null -ne $callsign -and $callsign -ne "") {
            Write-Host $callsign -ForegroundColor Green
        }
        else {
            Write-Host $icao24 -ForegroundColor Green
        }

        Write-Host "├─ ORIGIN: " -NoNewline -ForegroundColor Gray
        if ($null -ne $originCountry -and $originCountry -ne "") {
            Write-Host $originCountry -ForegroundColor Green
        }
        else {
            Write-Host "-" -ForegroundColor DarkGray
        }

        Write-Host "├─ ALTITUDE: " -NoNewline -ForegroundColor Gray
        if (-not $onGround -and $null -ne $baroAltitude -and $baroAltitude -ne 0) {
            Write-Host "$([math]::Round($baroAltitude, 0))m" -ForegroundColor Green
        }
        else {
            Write-Host "-" -ForegroundColor DarkGray
        }

        Write-Host "└─ VELOCITY: " -NoNewline -ForegroundColor Gray
        if (-not $onGround -and $null -ne $velocity -and $velocity -ne 0) {
            Write-Host "$([math]::Round($velocity, 0))m/s" -ForegroundColor Green
        }
        else {
            Write-Host "-" -ForegroundColor DarkGray
        }

        Write-Host ""

        # Show additional aircraft if any
        if ($statesCount -gt 1) {
            Write-Host "OTHER AIRCRAFT IN AREA:" -ForegroundColor Yellow
            for ($i = 1; $i -lt [math]::Min($statesCount, 6); $i++) {
                $otherPlane = $states[$i]
                $otherIcao24 = $otherPlane[0]
                $otherCallsign = if ($null -ne $otherPlane[1]) { $otherPlane[1].Trim() } else { $otherIcao24 }
                $otherBaroAltitude = $otherPlane[7]  # Can be null
                $otherOnGround = $otherPlane[8]
                $otherVelocity = $otherPlane[9]  # Can be null

                $status = if ($otherOnGround) { "Ground" } else {
                    if ($null -ne $otherBaroAltitude) { "$([math]::Round($otherBaroAltitude, 0))m" } else { "Flying" }
                }

                $velocityInfo = if ($null -ne $otherVelocity -and $otherVelocity -ne 0) {
                    ", Velocity: $([math]::Round($otherVelocity, 0))m/s"
                } else {
                    ""
                }

                Write-Host "  $otherCallsign - $status$velocityInfo" -ForegroundColor Cyan
            }
            if ($statesCount -gt 6) {
                Write-Host "  ... and $($statesCount - 6) more" -ForegroundColor DarkGray
            }
        }
    }
    else {
        Write-Host "No aircraft detected in the area." -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host ("=" * 50) -ForegroundColor Cyan
}

function Format-AircraftHTML {
    param($AircraftData, $Location)

    $states = $AircraftData.states
    $statesCount = if ($states) { $states.Count } else { 0 }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OpenSky Aircraft Tracker</title>
    <style>
        /* Import JetBrains Mono font */
        @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;700&display=swap');

        /* CSS Variables */
        :root {
            /* Base font size */
            font-size: 10px;

            /* Colors */
            --color-primary: hsl(43, 50%, 70%);
            --color-positive: hsl(120, 50%, 60%);
            --color-negative: hsl(0, 70%, 60%);

            /* Dark theme background */
            --color-bg-dark: hsl(220, 13%, 18%);
            --color-bg-dark-lighter: hsl(220, 13%, 22%);
            --color-bg-dark-lightest: hsl(220, 13%, 25%);

            /* Text colors for dark theme */
            --color-text-bright: hsl(220, 15%, 85%);
            --color-text-normal: hsl(220, 15%, 70%);
            --color-text-muted: hsl(220, 15%, 55%);
            --color-text-dim: hsl(220, 15%, 40%);

            /* Spacing */
            --spacing-xs: 5px;
            --spacing-sm: 10px;
            --spacing-md: 15px;
            --spacing-lg: 20px;
            --spacing-xl: 30px;

            /* Font sizes */
            --font-size-h1: 1.7rem;
            --font-size-h2: 1.6rem;
            --font-size-h3: 1.5rem;
            --font-size-h4: 1.4rem;
            --font-size-base: 1.3rem;
            --font-size-small: 1.2rem;
            --font-size-xs: 1.1rem;

            /* Border radius */
            --border-radius: 5px;
        }

        /* Base styles */
        body {
            font-family: 'JetBrains Mono', monospace;
            line-height: 1.6;
            font-size: var(--font-size-base);
            color: var(--color-text-normal);
            background-color: var(--color-bg-dark);
            margin: 0;
            padding: var(--spacing-lg);
        }

        /* Layout */
        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: var(--spacing-md);
        }

        /* Header */
        .header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-bottom: 1px solid var(--color-bg-dark-lighter);
            padding-bottom: var(--spacing-sm);
            margin-bottom: var(--spacing-lg);
        }

        .title {
            font-size: var(--font-size-h1);
            font-weight: bold;
            color: var(--color-text-bright);
        }

        .timestamp {
            color: var(--color-text-dim);
            font-size: var(--font-size-xs);
        }

        /* Location info */
        .location-info {
            background-color: var(--color-bg-dark-lighter);
            padding: var(--spacing-md);
            border-radius: var(--border-radius);
            margin-bottom: var(--spacing-lg);
            border-left: 4px solid var(--color-primary);
            color: var(--color-text-normal);
        }

        /* Aircraft cards */
        .featured-aircraft {
            background-color: var(--color-bg-dark-lighter);
            border-radius: var(--border-radius);
            padding: var(--spacing-md);
            margin-bottom: var(--spacing-lg);
            border: 1px solid var(--color-bg-dark-lightest);
        }

        .featured-title {
            font-size: var(--font-size-h3);
            font-weight: bold;
            color: var(--color-text-bright);
            margin-bottom: var(--spacing-md);
            border-bottom: 2px solid var(--color-primary);
            padding-bottom: var(--spacing-xs);
        }

        /* Grids */
        .grid-2 {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: var(--spacing-md);
        }

        .grid-4 {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: var(--spacing-md);
        }

        /* Data cards */
        .data-card {
            padding: var(--spacing-md);
            background-color: var(--color-bg-dark-lightest);
            border-radius: var(--border-radius);
        }

        .data-value {
            font-size: var(--font-size-h4);
            font-weight: bold;
            color: var(--color-primary);
        }

        .data-label {
            font-size: var(--font-size-small);
            color: var(--color-text-normal);
            text-transform: uppercase;
            font-weight: bold;
            margin-top: var(--spacing-xs);
            letter-spacing: 0.5px;
        }

        /* Aircraft list */
        .aircraft-list {
            margin-top: var(--spacing-lg);
        }

        .aircraft-item {
            display: flex;
            justify-content: space-between;
            padding: var(--spacing-md);
            border-bottom: 1px solid var(--color-bg-dark-lightest);
            color: var(--color-text-normal);
        }

        .aircraft-item:last-child {
            border-bottom: none;
        }

        .aircraft-callsign {
            font-weight: bold;
            color: var(--color-text-bright);
        }

        .aircraft-details {
            color: var(--color-text-muted);
        }

        /* Empty state */
        .no-data {
            text-align: center;
            padding: var(--spacing-xl);
            color: var(--color-text-dim);
            font-style: italic;
        }

        /* Footer */
        .footer {
            text-align: center;
            margin-top: var(--spacing-lg);
            font-size: var(--font-size-xs);
            color: var(--color-text-dim);
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="title">OpenSky Aircraft Tracker</div>
            <div class="timestamp">Last updated: $timestamp</div>
        </div>

        <div class="location-info">
            Location: $($Location.Latitude), $($Location.Longitude) ($($Location.Method))
        </div>

        <div class="aircraft-count">
            <div class="featured-title">AIRCRAFT NEARBY: $statesCount</div>
        </div>
"@

    if ($statesCount -gt 0) {
        $plane = $states[0]

        # Extract data with proper field names according to API documentation
        $icao24 = $plane[0]
        $callsign = if ($null -ne $plane[1]) { $plane[1].Trim() } else { "" }
        $originCountry = if ($null -ne $plane[2]) { $plane[2].Trim() } else { "" }
        $baroAltitude = $plane[7]  # Can be null
        $onGround = $plane[8]
        $velocity = $plane[9]  # Can be null
        $trueTrack = $plane[10]  # Can be null
        $verticalRate = $plane[11]  # Can be null

        $displayCallsign = if ($null -ne $callsign -and $callsign -ne "") { $callsign } else { $icao24 }
        $displayOrigin = if ($null -ne $originCountry -and $originCountry -ne "") { $originCountry } else { "-" }
        $displayAltitude = if (-not $onGround -and $null -ne $baroAltitude -and $baroAltitude -ne 0) { "$([math]::Round($baroAltitude, 0))m" } else { "-" }
        $displayVelocity = if (-not $onGround -and $null -ne $velocity -and $velocity -ne 0) { "$([math]::Round($velocity, 0))m/s" } else { "-" }
        $displayHeading = if ($null -ne $trueTrack) { "$([math]::Round($trueTrack, 0))°" } else { "-" }
        $displayVerticalRate = if ($null -ne $verticalRate) {
            $direction = if ($verticalRate -gt 0) { "↑" } else { "↓" }
            "$direction $([math]::Abs([math]::Round($verticalRate, 0)))m/s"
        } else { "-" }
        $status = if ($onGround) { "On Ground" } else { "In Flight" }

        $html += @"
        <div class="featured-aircraft">
            <div class="featured-title">FEATURED AIRCRAFT</div>
            <div class="grid-2">
                <div class="data-card">
                    <div class="data-value">$displayCallsign</div>
                    <div class="data-label">CALLSIGN</div>
                </div>
                <div class="data-card">
                    <div class="data-value">$displayOrigin</div>
                    <div class="data-label">ORIGIN COUNTRY</div>
                </div>
            </div>
            <div class="grid-4" style="margin-top: 15px;">
                <div class="data-card">
                    <div class="data-value">$displayAltitude</div>
                    <div class="data-label">ALTITUDE</div>
                </div>
                <div class="data-card">
                    <div class="data-value">$displayVelocity</div>
                    <div class="data-label">VELOCITY</div>
                </div>
                <div class="data-card">
                    <div class="data-value">$displayHeading</div>
                    <div class="data-label">HEADING</div>
                </div>
                <div class="data-card">
                    <div class="data-value">$displayVerticalRate</div>
                    <div class="data-label">VERTICAL RATE</div>
                </div>
            </div>
            <div class="data-card" style="margin-top: 15px;">
                <div class="data-value">$status</div>
                <div class="data-label">STATUS</div>
            </div>
        </div>
"@

        # Show additional aircraft if any
        if ($statesCount -gt 1) {
            $html += @"
        <div class="aircraft-list">
            <div class="featured-title">OTHER AIRCRAFT IN AREA</div>
"@
            for ($i = 1; $i -lt [math]::Min($statesCount, 10); $i++) {
                $otherPlane = $states[$i]

                # Safely extract data with proper field names
                $otherIcao = $otherPlane[0]
                $otherCallsign = if ($null -ne $otherPlane[1]) { $otherPlane[1].Trim() } else { $otherIcao }
                $otherOriginCountry = if ($null -ne $otherPlane[2]) { $otherPlane[2].Trim() } else { "-" }
                $otherBaroAltitude = $otherPlane[7]  # Can be null
                $otherOnGround = $otherPlane[8]
                $otherVelocity = $otherPlane[9]  # Can be null

                $otherStatus = if ($otherOnGround) { "On Ground" } else {
                    if ($null -ne $otherBaroAltitude) { "Alt: $([math]::Round($otherBaroAltitude, 0))m" } else { "In Flight" }
                }

                $otherVelocityDisplay = if ($null -ne $otherVelocity) { ", Velocity: $([math]::Round($otherVelocity, 0))m/s" } else { "" }

                $html += @"
            <div class="aircraft-item">
                <div class="aircraft-callsign">$otherCallsign</div>
                <div class="aircraft-details">$otherStatus$otherVelocityDisplay</div>
            </div>
"@
            }

            if ($statesCount -gt 10) {
                $html += @"
            <div class="aircraft-item">
                <div class="aircraft-details" style="width: 100%; text-align: center;">... and $($statesCount - 10) more aircraft</div>
            </div>
"@
            }

            $html += @"
        </div>
"@
        }
    }
    else {
        $html += @"
        <div class="no-data">
            No aircraft detected in the area.
        </div>
"@
    }

    $html += @"
        <div class="footer">
            Powered by OpenSky Network API • Generated by PowerShell Aircraft Tracker
        </div>
    </div>
</body>
</html>
"@
    return $html
}

# Main execution
Write-Host "Aircraft Tracker Starting..." -ForegroundColor Green

# Get location
if ($PSBoundParameters.ContainsKey('Latitude') -and $PSBoundParameters.ContainsKey('Longitude')) {
    # Use manually specified coordinates
    $location = @{
        Latitude  = $Latitude
        Longitude = $Longitude
        Method    = "Manual Input"
    }
    Write-Host "Using manually specified coordinates." -ForegroundColor Yellow
}
else {
    # Get location automatically using IP geolocation
    Write-Host "Attempting to determine location via IP geolocation." -ForegroundColor Yellow
    Write-Host "You can also provide coordinates manually:" -ForegroundColor Yellow
    Write-Host "Example: .\AircraftTracker.ps1 -Latitude 48.8566 -Longitude 2.3522" -ForegroundColor Gray

    $location = Get-LocationFromIP
    if (-not $location) {
        Write-Error "Could not determine location. Please provide coordinates manually using -Latitude and -Longitude parameters."
        exit 1
    }
}

Write-Host "Location found: $($location.Latitude), $($location.Longitude) using $($location.Method)" -ForegroundColor Green

# Cache functions
function Get-CachedData {
    if ($NoCache -or -not (Test-Path $script:CacheFile)) {
        return $null
    }

    try {
        $cacheData = Import-Clixml -Path $script:CacheFile
        $currentTime = Get-Date

        # Check if cache is still valid
        if ($currentTime -lt $cacheData.Expiry) {
            Write-Host "Using cached data (expires in $([math]::Round(($cacheData.Expiry - $currentTime).TotalSeconds)) seconds)" -ForegroundColor Cyan
            return $cacheData.Data
        }
    }
    catch {
        Write-Warning "Cache file is corrupted or invalid. Will fetch fresh data."
    }

    return $null
}

function Save-CacheData {
    param($Data)

    if ($NoCache) {
        return
    }

    try {
        $cacheData = @{
            Data = $Data
            Expiry = (Get-Date).AddMinutes($CacheMinutes)
        }

        $cacheData | Export-Clixml -Path $script:CacheFile -Force
        Write-Host "Data cached for $CacheMinutes minutes" -ForegroundColor Cyan
    }
    catch {
        Write-Warning "Failed to cache data: $_"
    }
}

# Try to get data from cache first
$aircraftData = Get-CachedData

# If no cached data, get fresh data from API
if (-not $aircraftData) {
    $aircraftData = Get-AircraftData -Latitude $location.Latitude -Longitude $location.Longitude -Radius $Radius
    if (-not $aircraftData -or -not $aircraftData.states) {
        Write-Warning "Could not fetch aircraft data or no aircraft data available."
        # Create empty data structure instead of exiting
        $aircraftData = [PSCustomObject]@{
            states = @()
            time = Get-Date
        }
    }

    # Save to cache for future use
    Save-CacheData -Data $aircraftData
}

# Format and display results
if ($OutputHTML) {
    $html = Format-AircraftHTML -AircraftData $aircraftData -Location $location
    $htmlFile = "aircraft_data.html"
    $html | Out-File -FilePath $htmlFile -Encoding UTF8
    Write-Host "HTML output saved to: $htmlFile" -ForegroundColor Green
    if (Get-Command "start" -ErrorAction SilentlyContinue) {
        Start-Process $htmlFile
    }
}
else {
    Format-AircraftConsole -AircraftData $aircraftData -Location $location
}

Write-Host "Refresh completed at $(Get-Date)" -ForegroundColor Green
