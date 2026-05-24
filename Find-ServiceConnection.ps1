<#
.LICENSE
    MIT License

    Copyright (c) 2026 Magomedbashir Kushtov (github.com/gearup2000)

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

.SYNOPSIS
    Search for Azure DevOps service connections by name.

.DESCRIPTION
    Searches for service connections in an Azure DevOps organization/project,
    optionally filtering by name (supports wildcards). Uses the az devops CLI.
    Supports Entra ID login (az login) and PAT token authentication.

.PARAMETER OrgUrl
    Azure DevOps organization URL (e.g. https://dev.azure.com/MyOrg).
    Falls back to AZDO_ORG_SERVICE_URL environment variable if not provided.

.PARAMETER Project
    Project name or ID to search within. If omitted, searches all projects.

.PARAMETER Name
    Service connection name or pattern to filter by (supports * wildcards).
    Defaults to '*' (all connections).

.PARAMETER ConnectionType
    Optional: filter by endpoint type (e.g. 'azurerm', 'github', 'kubernetes',
    'dockerregistry', 'externaltfs', 'git').

.PARAMETER AuthType
    Authentication method: 'EntraID' (default) or 'PAT'.

.PARAMETER PatToken
    PAT token to use when AuthType is 'PAT'. If omitted, falls back to the
    AZURE_DEVOPS_EXT_PAT environment variable.

.PARAMETER ExportCsv
    Optional path to export results as a CSV file (e.g. results.csv).

.EXAMPLE
    .\Find-ServiceConnection.ps1 -OrgUrl https://dev.azure.com/MyOrg -Name "prod-*"

.EXAMPLE
    .\Find-ServiceConnection.ps1 -OrgUrl https://dev.azure.com/MyOrg -Project "MyProject" -Name "prod-azure"

.EXAMPLE
    .\Find-ServiceConnection.ps1 -OrgUrl https://dev.azure.com/MyOrg -ConnectionType azurerm

.EXAMPLE
    .\Find-ServiceConnection.ps1 -OrgUrl https://dev.azure.com/MyOrg -AuthType PAT -PatToken "mypat..." -Name "prod-*"

.EXAMPLE
    .\Find-ServiceConnection.ps1 -OrgUrl https://dev.azure.com/MyOrg -Name "prod-*" -ExportCsv results.csv
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OrgUrl = $env:AZDO_ORG_SERVICE_URL,

    [Parameter()]
    [string]$Project,

    [Parameter()]
    [string]$Name,

    [Parameter()]
    [string]$ConnectionType,

    [Parameter()]
    [ValidateSet('EntraID', 'PAT')]
    [string]$AuthType = 'EntraID',

    [Parameter()]
    [string]$PatToken,

    [Parameter()]
    [string]$ExportCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helper functions

function Initialize-AzDevOpsExtension {
    $null = az extension show --name azure-devops 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing azure-devops CLI extension..." -ForegroundColor Yellow
        $out = az extension add --name azure-devops 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install azure-devops extension. Details: $out"
        }
    }
}

function Test-AzLogin {
    $null = az account show 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-PatSet {
    return (-not [string]::IsNullOrWhiteSpace($env:AZURE_DEVOPS_EXT_PAT))
}

function Get-AllProject {
    param([string]$Org)
    $projects = az devops project list --org $Org --query "value[].name" -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to list projects: $projects" }
    return @($projects | Where-Object { $_ -and $_.Trim() })
}

function Get-ServiceConnection {
    param(
        [string]$Org,
        [string]$ProjectName
    )

    $cliArgs = @(
        'devops', 'service-endpoint', 'list',
        '--org', $Org,
        '--project', $ProjectName,
        '--output', 'json'
    )

    $result = az @cliArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not retrieve service connections for project '$ProjectName': $result"
        return @()
    }

    $parsed = $result | ConvertFrom-Json
    return $(if ($parsed) { @($parsed) } else { @() })
}

#endregion

#region Validation / Interactive prompts

# ── OrgUrl ────────────────────────────────────────────────────────────────────
if (-not $OrgUrl) {
    Write-Host ''
    Write-Host '  Azure DevOps Service Connection Finder' -ForegroundColor Cyan
    Write-Host '  ──────────────────────────────────────' -ForegroundColor DarkGray
    Write-Host '  No parameters supplied — entering interactive mode.' -ForegroundColor DarkGray
    Write-Host '  (Press Ctrl+C at any time to cancel)' -ForegroundColor DarkGray
    Write-Host ''

    do {
        $OrgUrl = (Read-Host '  Organization URL (e.g. https://dev.azure.com/MyOrg)').Trim()
        if (-not $OrgUrl) { Write-Host '  Organization URL is required.' -ForegroundColor Yellow }
    } while (-not $OrgUrl)
}

# ── AuthType ─────────────────────────────────────────────────────────────────
if (-not $PSBoundParameters.ContainsKey('AuthType')) {
    Write-Host ''
    Write-Host '  Authentication type:' -ForegroundColor White
    Write-Host '    [1] Entra ID / az login  (default)' -ForegroundColor Gray
    Write-Host '    [2] PAT token' -ForegroundColor Gray
    $authChoice = (Read-Host '  Choice [1]').Trim()
    $AuthType = if ($authChoice -eq '2') { 'PAT' } else { 'EntraID' }
}

# ── PatToken (only when PAT selected and not already set) ─────────────────────
if ($AuthType -eq 'PAT' -and -not $PatToken -and -not $env:AZURE_DEVOPS_EXT_PAT) {
    Write-Host ''
    do {
        # Read-Host -AsSecureString keeps the token off the screen
        $securePat = Read-Host '  PAT token' -AsSecureString
        $PatToken  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                         [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePat))
        if (-not $PatToken) { Write-Host '  PAT token is required when using PAT authentication.' -ForegroundColor Yellow }
    } while (-not $PatToken)
}

# ── Optional filters (only prompt when running interactively, i.e. OrgUrl was not supplied) ──
if (-not $PSBoundParameters.ContainsKey('OrgUrl')) {
    Write-Host ''
    $inputProject = (Read-Host '  Project name (leave blank to search all projects)').Trim()
    if ($inputProject) { $Project = $inputProject }

    Write-Host '  Name filter examples: "test*" = starts with test, "*prod*" = contains prod, "sc-?" = single char after sc-' -ForegroundColor DarkGray
    $inputName = (Read-Host '  Name filter, wildcards OK (leave blank for all, default: *)').Trim()
    if ($inputName) { $Name = $inputName }

    Write-Host '  Connection type filter: azurerm, github, kubernetes, dockerregistry, externaltfs, git'
    $inputType = (Read-Host '  Connection type (leave blank for all)').Trim()
    if ($inputType) { $ConnectionType = $inputType }

    $inputCsv = (Read-Host '  Export to CSV path (leave blank to skip, e.g. results.csv)').Trim()
    if ($inputCsv) { $ExportCsv = $inputCsv }

    Write-Host ''
}

Initialize-AzDevOpsExtension

# Handle authentication
if ($AuthType -eq 'PAT') {
    $pat = if ($PatToken) { $PatToken } else { $env:AZURE_DEVOPS_EXT_PAT }
    if (-not $pat) {
        throw "PAT authentication requires a token. Provide -PatToken or set the AZURE_DEVOPS_EXT_PAT environment variable."
    }
    $env:AZURE_DEVOPS_EXT_PAT = $pat
    Write-Host "Using PAT token authentication." -ForegroundColor Cyan
} else {
    # Entra ID — ensure logged in
    if (-not (Test-AzLogin)) {
        Write-Host "Not signed in. Running az login..." -ForegroundColor Yellow
        az login --use-device-code --allow-no-subscriptions --output none
        if ($LASTEXITCODE -ne 0) {
            throw "az login failed. Please sign in and try again."
        }
    }
    $acct = az account show --query "user.name" -o tsv 2>$null
    Write-Host "Authenticated as: $acct" -ForegroundColor Cyan
}

#endregion

#region Main

$namePattern = if ($Name) { $Name } else { '*' }

$projectList = if ($Project) {
    @($Project)
} else {
    Write-Host "No project specified - searching all projects in '$OrgUrl'..." -ForegroundColor Cyan
    Get-AllProject -Org $OrgUrl
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($proj in $projectList) {
    $proj = $proj.Trim()
    if (-not $proj) { continue }

    Write-Verbose "Scanning project: $proj"
    $endpoints = Get-ServiceConnection -Org $OrgUrl -ProjectName $proj

    foreach ($ep in $endpoints) {
        if ($ep.name -notlike $namePattern) { continue }
        if ($ConnectionType -and ($ep.type -ne $ConnectionType)) { continue }

        $results.Add([PSCustomObject]@{
            Project   = $proj
            Name      = $ep.name
            Id        = $ep.id
            Type      = $ep.type
            Url       = $ep.url
            CreatedBy = $ep.createdBy.displayName
            IsShared  = $ep.isShared
            IsReady   = $ep.isReady
            DevOpsUrl = "$($OrgUrl.TrimEnd('/'))/$proj/_settings/adminservices?resourceId=$($ep.id)"
        })
    }
}

#endregion

#region Output

if ($results.Count -eq 0) {
    $filterDesc = if ($Name) { " matching '$Name'" } else { "" }
    Write-Host "No service connections found$filterDesc." -ForegroundColor Yellow
} else {
    Write-Host "`nFound $($results.Count) service connection(s):`n" -ForegroundColor Green
    $results | Format-Table -AutoSize -Property Project, Name, Id, Type, Url, CreatedBy, IsShared, IsReady

    Write-Host 'Azure DevOps direct links:' -ForegroundColor Cyan
    foreach ($r in $results) {
        Write-Host "  $($r.Project) / $($r.Name)" -ForegroundColor White
        Write-Host "  $($r.DevOpsUrl)" -ForegroundColor DarkCyan
        Write-Host ''
    }
}

if ($ExportCsv) {
    $results | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Results exported to: $ExportCsv" -ForegroundColor Green
}

# Output objects to the pipeline for scripting use
Write-Output $results

#endregion
