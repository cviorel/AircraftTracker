# Aircraft Tracker

A PowerShell-based aircraft tracking tool that uses the OpenSky Network API to display real-time information about aircraft in your vicinity or any specified location.

![Aircraft Tracker](https://img.shields.io/badge/Aircraft-Tracker-blue)
![PowerShell](https://img.shields.io/badge/PowerShell-7.0+-5391FE?logo=powershell&logoColor=white)
![Version](https://img.shields.io/badge/Version-1.1.0-success)

## Overview

Aircraft Tracker fetches and displays aircraft data from the OpenSky Network API for a specified location. It can determine your location automatically using IP geolocation or accept manual coordinates. The tool provides both console and HTML output formats, making it versatile for different use cases.

## Features

- **Automatic Location Detection**: Uses IP geolocation to determine your current location
- **Manual Coordinate Input**: Specify exact latitude and longitude coordinates
- **Adjustable Search Radius**: Customize the area to search for aircraft
- **Dual Output Formats**:
  - Console output with color-coded information
  - Rich HTML output with responsive design
- **Response Caching**: Reduces API calls and improves performance
- **Detailed Aircraft Information**:
  - Callsign
  - Origin country
  - Altitude
  - Velocity
  - Heading
  - Vertical rate
  - Flight status (ground/air)

## Requirements

- PowerShell 5.1 or higher (PowerShell 7+ recommended)
- Internet connection
- No additional modules required

## Installation

1. Download the `AircraftTracker.ps1` script
2. No installation required - the script runs directly in PowerShell

## Usage

### Basic Usage

Run the script without parameters to use automatic location detection:

```powershell
.\AircraftTracker.ps1
```

### Specify Location

Provide exact coordinates:

```powershell
.\AircraftTracker.ps1 -Latitude 48.8566 -Longitude 2.3522
```

### Customize Search Radius

Adjust the search radius (in degrees, default is 0.1 which is approximately 11km):

```powershell
.\AircraftTracker.ps1 -Radius 0.2
```

### Generate HTML Output

Create a rich HTML visualization instead of console output:

```powershell
.\AircraftTracker.ps1 -OutputHTML
```

### Disable Caching

Force fresh data retrieval on each run:

```powershell
.\AircraftTracker.ps1 -NoCache
```

### Adjust Cache Duration

Change how long results are cached (in minutes):

```powershell
.\AircraftTracker.ps1 -CacheMinutes 5
```

## Parameters

| Parameter       | Description                             | Default       |
| --------------- | --------------------------------------- | ------------- |
| `-Radius`       | Search radius in degrees (0.1° ≈ 11km)  | 0.1           |
| `-OutputHTML`   | Generate HTML output instead of console | False         |
| `-Latitude`     | Manually specified latitude             | Auto-detected |
| `-Longitude`    | Manually specified longitude            | Auto-detected |
| `-NoCache`      | Disable caching of API responses        | False         |
| `-CacheMinutes` | How long to cache results (minutes)     | 2             |

## Output Examples

### Console Output

The console output provides a clean, color-coded display of nearby aircraft with the following information:

- Total aircraft count
- Featured aircraft details (callsign, origin, altitude, velocity)
- List of other aircraft in the area

### HTML Output

The HTML output creates a responsive, modern interface with:

- Dark theme design
- Detailed aircraft information in cards
- Responsive grid layout
- Timestamp and location information
- List of all detected aircraft

The HTML file is saved as `aircraft_data.html` in the current directory and automatically opened in your default browser.

## API Limitations

The OpenSky Network API has the following rate limits for anonymous users:

- Maximum 400 requests per day
- Maximum 4 requests per minute

The script implements caching and retry logic to help manage these limitations.

## Notes

- Distance calculations use the haversine formula for accuracy
- The script handles API errors gracefully with retry logic
- Geolocation is attempted through multiple services for reliability

## Author

Viorel-Felix Ciucu

## License

This project is available as open source under the terms of the MIT License.

## Acknowledgements

- [OpenSky Network](https://opensky-network.org/) for providing the aircraft tracking API
- [IP-API](https://ip-api.com/) and [ipinfo.io](https://ipinfo.io/) for geolocation services
