Set-StrictMode -Version Latest

function Get-Percentile {
    <#
    .SYNOPSIS
    Returns a linearly interpolated percentile from a non-empty numeric sample.

    .DESCRIPTION
    Uses the inclusive zero-based rank `(n - 1) * percentile`. This makes the
    median the middle observation for odd sample counts and the mean of the two
    middle observations for even sample counts. Keeping this rule here gives
    the measurement report and publication checker one statistic owner.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [double[]]$Values,

        [Parameter(Mandatory)]
        [ValidateRange(0.0, 1.0)]
        [double]$Percentile
    )

    if ($Values.Count -eq 0) {
        throw 'cannot calculate a percentile from an empty sample'
    }

    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 1) {
        return [double]$sorted[0]
    }

    $rank = ($sorted.Count - 1) * $Percentile
    $lowerIndex = [int][math]::Floor($rank)
    $upperIndex = [int][math]::Ceiling($rank)
    if ($lowerIndex -eq $upperIndex) {
        return [double]$sorted[$lowerIndex]
    }

    $weight = $rank - $lowerIndex
    return [double]$sorted[$lowerIndex] +
        (([double]$sorted[$upperIndex] - [double]$sorted[$lowerIndex]) * $weight)
}
