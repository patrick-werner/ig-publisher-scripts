Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ig-publisher-batch-tests-" + [guid]::NewGuid())
$mockBin = Join-Path $tempRoot "mock bin"
$originalPath = $env:Path
$originalPublisherHome = $env:FHIR_PUBLISHER_HOME
$originalUserProfile = $env:USERPROFILE
$testCount = 0

function Assert-Contains {
    param(
        [string] $Actual,
        [string] $Expected,
        [string] $Context
    )

    if (-not $Actual.Contains($Expected)) {
        throw "$Context`nExpected output to contain: $Expected`nActual output:`n$Actual"
    }
}

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Context
    )

    if (-not $Condition) {
        throw $Context
    }
}

function Invoke-Batch {
    param(
        [string] $WorkingDirectory,
        [string] $Command,
        [string[]] $InputLines = @()
    )

    $inputFile = Join-Path $WorkingDirectory ("stdin-" + [guid]::NewGuid() + ".txt")
    [System.IO.File]::WriteAllText(
        $inputFile,
        (($InputLines -join "`r`n") + "`r`n"),
        [System.Text.Encoding]::ASCII
    )

    Push-Location $WorkingDirectory
    try {
        $commandWithInput = "$Command < `"$inputFile`""
        $output = (& $env:ComSpec /d /c $commandWithInput 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
        Remove-Item $inputFile -Force
    }

    if ($exitCode -ne 0) {
        throw "Batch command failed with exit code $exitCode`: $Command`n$output"
    }

    return $output
}

function New-Fixture {
    param([string] $Name)

    $fixtureRoot = Join-Path $tempRoot $Name
    $projectRoot = Join-Path $fixtureRoot "IG project"
    $publisherHome = Join-Path $fixtureRoot "shared publisher home"
    New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
    Copy-Item (Join-Path $repoRoot "_build.bat") $projectRoot
    Copy-Item (Join-Path $repoRoot "_genonce.bat") $projectRoot
    Copy-Item (Join-Path $repoRoot "_updatePublisher.bat") $projectRoot

    return [pscustomobject]@{
        Root = $fixtureRoot
        Project = $projectRoot
        PublisherHome = $publisherHome
        LocalJar = Join-Path $projectRoot "input-cache\publisher.jar"
        ParentJar = Join-Path $fixtureRoot "publisher.jar"
        GlobalJar = Join-Path $publisherHome "publisher.jar"
    }
}

function Add-EmptyFile {
    param([string] $Path)

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    New-Item -ItemType File -Path $Path -Force | Out-Null
}

function Test-RuntimeLookup {
    param(
        [string] $Script,
        [hashtable] $Case
    )

    $fixture = New-Fixture "$($Script.Replace('.', '-'))-$($Case.Name)"
    if ($Case.Local) { Add-EmptyFile $fixture.LocalJar }
    if ($Case.Parent) { Add-EmptyFile $fixture.ParentJar }
    if ($Case.Global) { Add-EmptyFile $fixture.GlobalJar }
    $env:FHIR_PUBLISHER_HOME = $fixture.PublisherHome

    switch ($Case.Expected) {
        "local" { $expectedJar = $fixture.LocalJar }
        "parent" { $expectedJar = "..\publisher.jar" }
        "global" { $expectedJar = $fixture.GlobalJar }
        default { throw "Unknown expected location: $($Case.Expected)" }
    }

    $output = Invoke-Batch $fixture.Project "$Script probe"
    Assert-Contains $output "MOCK_JAVA -jar `"$expectedJar`" -ig ." "$Script lookup case $($Case.Name)"
    $script:testCount++
}

function Test-UpdateTarget {
    param(
        [string] $Script,
        [bool] $HasLocalPublisher
    )

    $state = if ($HasLocalPublisher) { "local" } else { "global" }
    $fixture = New-Fixture "$($Script.Replace('.', '-'))-update-$state"
    $env:FHIR_PUBLISHER_HOME = $fixture.PublisherHome
    Add-EmptyFile $fixture.ParentJar
    if ($HasLocalPublisher) { Add-EmptyFile $fixture.LocalJar }

    $logPath = Join-Path $fixture.Root "powershell-calls.log"
    $env:MOCK_POWERSHELL_LOG = $logPath
    $command = if ($Script -eq "_build.bat") { "$Script update" } else { $Script }
    $output = Invoke-Batch $fixture.Project $command @("Y", "N", "")
    $calls = if (Test-Path $logPath) { Get-Content $logPath -Raw } else { "" }
    $expectedTarget = if ($HasLocalPublisher) { $fixture.LocalJar } else { $fixture.GlobalJar }

    Assert-Contains $calls $expectedTarget "$Script update target $state"
    if ($HasLocalPublisher) {
        Assert-True (-not (Test-Path $fixture.GlobalJar)) "$Script unexpectedly targeted the global publisher"
    }
    else {
        Assert-True (Test-Path $fixture.PublisherHome) "$Script did not create the publisher home"
        Assert-Contains $output "FHIR Publisher Home" "$Script did not report the global update target"
    }
    $script:testCount++
}

try {
    New-Item -ItemType Directory -Path $mockBin -Force | Out-Null
    Set-Content -Path (Join-Path $mockBin "java.cmd") -Encoding ASCII -Value @"
@ECHO OFF
ECHO MOCK_JAVA %*
EXIT /B 0
"@
    Set-Content -Path (Join-Path $mockBin "powershell.cmd") -Encoding ASCII -Value @"
@ECHO OFF
IF DEFINED MOCK_POWERSHELL_LOG ECHO %*>>"%MOCK_POWERSHELL_LOG%"
EXIT /B 0
"@
    $env:Path = "$mockBin;$originalPath"

    $lookupCases = @(
        @{ Name = "local-only"; Local = $true; Parent = $false; Global = $false; Expected = "local" },
        @{ Name = "parent-only"; Local = $false; Parent = $true; Global = $false; Expected = "parent" },
        @{ Name = "global-only"; Local = $false; Parent = $false; Global = $true; Expected = "global" },
        @{ Name = "local-parent-global"; Local = $true; Parent = $true; Global = $true; Expected = "local" },
        @{ Name = "parent-global"; Local = $false; Parent = $true; Global = $true; Expected = "parent" }
    )

    foreach ($script in @("_build.bat", "_genonce.bat")) {
        foreach ($case in $lookupCases) {
            Test-RuntimeLookup $script $case
        }

        $missingFixture = New-Fixture "$($script.Replace('.', '-'))-missing"
        $env:FHIR_PUBLISHER_HOME = $missingFixture.PublisherHome
        $missingOutput = Invoke-Batch $missingFixture.Project "$script probe"
        Assert-Contains $missingOutput "IG Publisher NOT FOUND in input-cache, parent folder, or FHIR publisher home" "$script missing publisher"
        $script:testCount++
    }

    $defaultFixture = New-Fixture "default-user-profile"
    $env:FHIR_PUBLISHER_HOME = $null
    $env:USERPROFILE = Join-Path $defaultFixture.Root "user profile"
    $defaultJar = Join-Path $env:USERPROFILE ".fhir\tools\publisher\publisher.jar"
    Add-EmptyFile $defaultJar
    foreach ($script in @("_build.bat", "_genonce.bat")) {
        $defaultOutput = Invoke-Batch $defaultFixture.Project "$script probe"
        Assert-Contains $defaultOutput "MOCK_JAVA -jar `"$defaultJar`" -ig ." "$script default USERPROFILE publisher home"
        $testCount++
    }

    foreach ($script in @("_build.bat", "_updatePublisher.bat")) {
        Test-UpdateTarget $script $true
        Test-UpdateTarget $script $false
    }

    Write-Host "PASS: $testCount Windows batch checks"
}
finally {
    $env:Path = $originalPath
    $env:FHIR_PUBLISHER_HOME = $originalPublisherHome
    $env:USERPROFILE = $originalUserProfile
    Remove-Item Env:MOCK_POWERSHELL_LOG -ErrorAction SilentlyContinue
    if (Test-Path $tempRoot) {
        Remove-Item $tempRoot -Recurse -Force
    }
}
