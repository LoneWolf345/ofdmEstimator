function Get-SnmpData {
    param (
        [string]$ipAddress,
        [string]$oid
    )
    $community = 'private'  # Adjust community as needed
    $snmpData = snmpwalk -v 2c -c $community $ipAddress $oid 2>&1
    if ($snmpData -like "*No Such Instance*") {
        Write-Host "No data returned for OID $oid"
        return $null
    } else {
        $result = ($snmpData -split ":")[-1].Trim()
        #Write-Host "Data retrieved for OID $oid : $result"
        return $result
    }
}

function Prompt-Or-Snmp {
    param (
        [string]$description,
        [string]$example,
        [string]$oid,
        [double]$conversionFactor = 1  # Default conversion factor is 1 (no conversion)
    )
    $value = Get-SnmpData -ipAddress $script:modemIp -oid $oid
    if ($null -eq $value) {
        Write-Host "Unable to retrieve $description via SNMP."
        $value = Read-Host "Please enter $description manually (e.g., $example)"
    } else {
        $convertedValue = [double]$value / $conversionFactor
        Write-Host "$description retrieved via SNMP: $convertedValue"
        $value = $convertedValue
    }
    return $value
}

function Calculate-Parameters {
    param (
        [double]$occupiedSpectrum,
        [double]$lowerBandEdge,
        [double]$avgModulationOrder,
        [double]$guardBand,
        [double]$excludedBand,
        [double]$subcarrierSpacing
    )

    #Write-Host "Calculating parameters with: occupiedSpectrum=$occupiedSpectrum, lowerBandEdge=$lowerBandEdge, avgModulationOrder=$avgModulationOrder, guardBand=$guardBand, excludedBand=$excludedBand, subcarrierSpacing=$subcarrierSpacing"

    $upperBandEdge = $lowerBandEdge + $occupiedSpectrum
    $numFftPoints = ($script:samplingRate * 1000) / $subcarrierSpacing
    $symbolPeriodUsec = 1000 / $subcarrierSpacing
    $cyclicPrefixUsec = $script:cyclicPrefix / $script:samplingRate
    $actualSymbolPeriodUsec = $symbolPeriodUsec + $cyclicPrefixUsec
    $symbolEfficiency = 100 * $symbolPeriodUsec / $actualSymbolPeriodUsec
    $modulatedSubcarriers = ($occupiedSpectrum - $guardBand - $excludedBand) * 1000 / $subcarrierSpacing

    $numPlcSubcarriers = if ($subcarrierSpacing -eq 50) { 8 } else { 16 }

    $numContPilots = [Math]::Min([Math]::Max(8, [Math]::Ceiling($script:pilotDensityM * $occupiedSpectrum / 190)), 120) + 8
    $numScatteredPilots = [Math]::Ceiling(($modulatedSubcarriers - $numPlcSubcarriers) / 128)
    
    Write-Host "Modulated Subcarriers: $modulatedSubcarriers"
    Write-Host "Excluded Subcarriers: $script:excludedSubcarriers"
    Write-Host "PLC Subcarriers: $numPlcSubcarriers"
    Write-Host "FFT Blocks: $script:numFftBlocks"
    Write-Host "Continuous Pilots: $numContPilots"
    Write-Host "Scattered Pilots: $numScatteredPilots"

    $effectiveSubcarriers = $modulatedSubcarriers - ($script:excludedSubcarriers + $numPlcSubcarriers * $script:numFftBlocks + $numContPilots + $numScatteredPilots)

#    Write-Host "Effective Subcarriers: $effectiveSubcarriers"
    return $actualSymbolPeriodUsec, $effectiveSubcarriers
}

function Calculate-DataRate {
    param (
        [double]$actualSymbolPeriodUsec,
        [double]$effectiveSubcarriers,
        [double]$avgModulationOrder,
        [double]$occupiedSpectrum
    )

    #Write-Host "Calculating data rate with: actualSymbolPeriodUsec=$actualSymbolPeriodUsec, effectiveSubcarriers=$effectiveSubcarriers, avgModulationOrder=$avgModulationOrder, occupiedSpectrum=$occupiedSpectrum"

    $ncpBitsPerMb = 48
    $subcarriersPerNcpMb = $ncpBitsPerMb / $script:ncpModulationOrder
    $numBitsInDataSubcarriers = $effectiveSubcarriers * $avgModulationOrder
    if ($script:numSymbolsPerProfile -gt 1) {
        $numBitsInDataSubcarriers *= $script:numSymbolsPerProfile
    }

    $numFullCodewords = [Math]::Floor($numBitsInDataSubcarriers / $script:ldpcFecCw[0])
    $numNcpMbs = $numFullCodewords + [Math]::Ceiling($script:numSymbolsPerProfile)

    $estimateShortenedCwSize = (($script:numSymbolsPerProfile * $effectiveSubcarriers - (($numNcpMbs + 1) * $subcarriersPerNcpMb)) * $avgModulationOrder) - ($script:ldpcFecCw[0] * $numFullCodewords)
    $shortenedCwData = [Math]::Max(0, $estimateShortenedCwSize - ($script:ldpcFecCw[2] - $script:ldpcFecCw[3] - $script:ldpcFecCw[4]))

    $totalDataBits = ($numFullCodewords * $script:ldpcFecCw[1]) + $shortenedCwData
    $rateAcrossWholeChannelGbps = $totalDataBits / ($actualSymbolPeriodUsec * $script:numSymbolsPerProfile * 1000)
    $phyEfficiency = $rateAcrossWholeChannelGbps * 1e3 / $occupiedSpectrum

    #Write-Host "Total Data Bits: $totalDataBits, Rate across Whole Channel [Gbps]: $rateAcrossWholeChannelGbps, PHY Efficiency: $phyEfficiency"
    return $totalDataBits, $rateAcrossWholeChannelGbps, $phyEfficiency
}

# Main script execution
$script:modemIp = Read-Host "Please enter the IP address of the modem"
$script:samplingRate = 204.8  # MHz
$script:cyclicPrefix = [int](Prompt-Or-Snmp -description "Ds Ofdm Cyclic Prefix" -example "512" -oid ".1.3.6.1.4.1.4491.2.1.28.1.9.1.8")
$script:subcarrierSpacing = [int](Prompt-Or-Snmp -description " Ds Subcarrier Spacing" -example "50 kHz" -oid ".1.3.6.1.4.1.4491.2.1.28.1.9.1.7")
$script:lowerBandEdge = [double](Prompt-Or-Snmp -description "Ds Lower Band Edge Frequency" -example "683.6 MHz" -oid ".1.3.6.1.4.1.4491.2.1.28.1.9.1.3" -conversionFactor 1000000)
$script:numFftBlocks = 1
$script:pilotDensityM = 48
$script:excludedSubcarriers = 20
$script:ncpModulationOrder = 6
$script:numSymbolsPerProfile = 1
$script:ldpcFecCw = @(16200, 14216, 1800, 168, 16)  # [CWSize, Infobits, Parity, BCH, CWheader]

$occupiedSpectrum = [double](Read-Host "Please enter the occupied spectrum in MHz (e.g., 96)")
$avgModulationOrder = [double](Read-Host "Please enter the average modulation order (4-14) (e.g. 10 = qam1024, 11 = qam2048, 12 = qam4096)")
$guardBand = [double](Read-Host "Please enter the guard band in MHz (e.g., 2)")
$excludedBand = [double](Read-Host "Please enter the excluded band in MHz (e.g., 2)")

$actualSymbolPeriodUsec, $effectiveSubcarriers = Calculate-Parameters $occupiedSpectrum $lowerBandEdge $avgModulationOrder $guardBand $excludedBand $subcarrierSpacing
$totalDataBits, $rateAcrossWholeChannelGbps, $phyEfficiency = Calculate-DataRate $actualSymbolPeriodUsec $effectiveSubcarriers $avgModulationOrder $occupiedSpectrum

#Write-Host "Total Data Bits: $totalDataBits"
Write-Host "Rate across Whole Channel [Gbps]: $rateAcrossWholeChannelGbps"
#Write-Host "Downstream PHY Efficiency: $phyEfficiency"
