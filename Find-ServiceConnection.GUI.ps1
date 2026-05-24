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
    GUI search tool for Azure DevOps service connections.

.DESCRIPTION
    Opens a Windows Forms app that searches service connections by organization,
    optional project, optional name wildcard, and optional connection type.
    Supports Entra ID login (az login) and PAT token authentication.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Placeholder simulation using Enter/Leave events with grey text
function Add-Placeholder {
    param(
        [System.Windows.Forms.TextBox]$TextBox,
        [string]$PlaceholderText,
        [string]$InitialValue = ''
    )
    $TextBox.Tag = $PlaceholderText
    if ($InitialValue) {
        $TextBox.Text      = $InitialValue
        $TextBox.ForeColor = [System.Drawing.SystemColors]::WindowText
    } else {
        $TextBox.Text      = $PlaceholderText
        $TextBox.ForeColor = [System.Drawing.Color]::Gray
    }
    $TextBox.Add_Enter({
        if ($this.ForeColor -eq [System.Drawing.Color]::Gray) {
            $this.Text      = ''
            $this.ForeColor = [System.Drawing.SystemColors]::WindowText
        }
    })
    $TextBox.Add_Leave({
        if ([string]::IsNullOrWhiteSpace($this.Text)) {
            $this.Text      = $this.Tag
            $this.ForeColor = [System.Drawing.Color]::Gray
        }
    })
}

# Returns the real value of a TextBox, treating grey placeholder text as empty
function Get-FieldValue {
    param([System.Windows.Forms.TextBox]$TextBox)
    if ($TextBox.ForeColor -eq [System.Drawing.Color]::Gray) { return '' }
    return $TextBox.Text.Trim()
}

#region Backend functions

function Initialize-AzDevOpsExtension {
    $null = az extension show --name azure-devops 2>$null
    if ($LASTEXITCODE -ne 0) {
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
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list projects for '$Org'. Details: $projects"
    }

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
        throw "Could not list service connections for '$ProjectName'. Details: $result"
    }

    $parsed = $result | ConvertFrom-Json
    return $(if ($parsed) { @($parsed) } else { @() })
}

function Find-ServiceConnection {
    param(
        [string]$Org,
        [string]$Project,
        [bool]$SearchAllProjects,
        [string]$NamePattern,
        [string]$ConnectionType
    )

    $projectList = if ($SearchAllProjects) {
        Get-AllProject -Org $Org
    } else {
        if (-not $Project) {
            throw "Project is required unless 'All Projects' is checked."
        }
        @($Project)
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($proj in $projectList) {
        $safeProject = $proj.Trim()
        if (-not $safeProject) { continue }

        $endpoints = Get-ServiceConnection -Org $Org -ProjectName $safeProject

        foreach ($ep in $endpoints) {
            if ($NamePattern -and ($ep.name -notlike $NamePattern)) { continue }
            if ($ConnectionType -and ($ep.type -ne $ConnectionType))  { continue }

            $results.Add([PSCustomObject]@{
                Project   = $safeProject
                Name      = $ep.name
                Type      = $ep.type
                Url       = $ep.url
                CreatedBy = $ep.createdBy.displayName
                IsReady   = $ep.isReady
                IsShared  = $ep.isShared
                DevOpsUrl = "$($Org.TrimEnd('/'))/$safeProject/_settings/adminservices?resourceId=$($ep.id)"
            })
        }
    }

    return $results
}

function ConvertTo-DataTable {
    param([System.Collections.Generic.List[PSCustomObject]]$Objects)
    $table = New-Object System.Data.DataTable
    if (-not $Objects -or $Objects.Count -eq 0) { return ,$table }
    $Objects[0].PSObject.Properties | ForEach-Object { [void]$table.Columns.Add($_.Name, [string]) }
    foreach ($obj in $Objects) {
        $row = $table.NewRow()
        $obj.PSObject.Properties | ForEach-Object { $row[$_.Name] = "$($_.Value)" }
        [void]$table.Rows.Add($row)
    }
    return ,$table
}

#endregion

#region Form construction

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Azure DevOps Service Connection Finder'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1220, 860)
$form.MinimumSize = New-Object System.Drawing.Size(1000, 700)

# ── Authentication group ──────────────────────────────────────────────────────
$grpAuth = New-Object System.Windows.Forms.GroupBox
$grpAuth.Text = 'Authentication'
$grpAuth.Location = New-Object System.Drawing.Point(10, 6)
$grpAuth.Size = New-Object System.Drawing.Size(1180, 90)
$grpAuth.Anchor = 'Top,Left,Right'

# Row 1: auth type selection
$radAAD = New-Object System.Windows.Forms.RadioButton
$radAAD.Text = 'Entra ID (az login)'
$radAAD.Location = New-Object System.Drawing.Point(10, 20)
$radAAD.AutoSize = $true
$radAAD.Checked = $true

$radPAT = New-Object System.Windows.Forms.RadioButton
$radPAT.Text = 'PAT Token'
$radPAT.Location = New-Object System.Drawing.Point(180, 20)
$radPAT.AutoSize = $true

# Login / Logout / status (right side, spanning both rows)
$btnLogin = New-Object System.Windows.Forms.Button
$btnLogin.Text = 'Login'
$btnLogin.Location = New-Object System.Drawing.Point(870, 16)
$btnLogin.Size = New-Object System.Drawing.Size(100, 28)

$btnLogout = New-Object System.Windows.Forms.Button
$btnLogout.Text = 'Logout'
$btnLogout.Location = New-Object System.Drawing.Point(980, 16)
$btnLogout.Size = New-Object System.Drawing.Size(100, 28)

$lblAuthStatus = New-Object System.Windows.Forms.Label
$lblAuthStatus.Text = 'Not authenticated'
$lblAuthStatus.ForeColor = [System.Drawing.Color]::Firebrick
$lblAuthStatus.Location = New-Object System.Drawing.Point(870, 54)
$lblAuthStatus.AutoSize = $true

# Row 2: PAT controls (shown when PAT radio selected)
$lblPAT = New-Object System.Windows.Forms.Label
$lblPAT.Text = 'PAT Token:'
$lblPAT.Location = New-Object System.Drawing.Point(10, 56)
$lblPAT.AutoSize = $true
$lblPAT.Visible = $false

$txtPAT = New-Object System.Windows.Forms.TextBox
$txtPAT.Location = New-Object System.Drawing.Point(90, 52)
$txtPAT.Size = New-Object System.Drawing.Size(500, 24)
$txtPAT.PasswordChar = [char]0x25CF
$txtPAT.Visible = $false

$grpAuth.Controls.AddRange(@(
    $radAAD, $radPAT,
    $lblPAT, $txtPAT,
    $btnLogin, $btnLogout, $lblAuthStatus
))

# ── Filter row 1: Org URL ─────────────────────────────────────────────────────
$lblOrg = New-Object System.Windows.Forms.Label
$lblOrg.Text = 'Organization URL:'
$lblOrg.Location = New-Object System.Drawing.Point(16, 114)
$lblOrg.AutoSize = $true

$txtOrg = New-Object System.Windows.Forms.TextBox
$txtOrg.Location = New-Object System.Drawing.Point(150, 110)
$txtOrg.Size = New-Object System.Drawing.Size(640, 24)
Add-Placeholder $txtOrg 'https://dev.azure.com/YourOrg' -InitialValue $env:AZDO_ORG_SERVICE_URL

# ── Filter row 2: Project ─────────────────────────────────────────────────────
$lblProject = New-Object System.Windows.Forms.Label
$lblProject.Text = 'Project:'
$lblProject.Location = New-Object System.Drawing.Point(16, 150)
$lblProject.AutoSize = $true

$txtProject = New-Object System.Windows.Forms.TextBox
$txtProject.Location = New-Object System.Drawing.Point(150, 146)
$txtProject.Size = New-Object System.Drawing.Size(320, 24)
Add-Placeholder $txtProject 'Leave blank to search all projects'

$chkAllProjects = New-Object System.Windows.Forms.CheckBox
$chkAllProjects.Text = 'All Projects'
$chkAllProjects.Location = New-Object System.Drawing.Point(486, 147)
$chkAllProjects.AutoSize = $true

# ── Filter row 3: Name / Type ─────────────────────────────────────────────────
$lblName = New-Object System.Windows.Forms.Label
$lblName.Text = 'Name Pattern:'
$lblName.Location = New-Object System.Drawing.Point(16, 184)
$lblName.AutoSize = $true

$txtName = New-Object System.Windows.Forms.TextBox
$txtName.Location = New-Object System.Drawing.Point(150, 180)
$txtName.Size = New-Object System.Drawing.Size(320, 24)
Add-Placeholder $txtName 'e.g.  test*  ·  *prod*  ·  sc-?  ·  (blank = all)'

$lblType = New-Object System.Windows.Forms.Label
$lblType.Text = 'Connection Type:'
$lblType.Location = New-Object System.Drawing.Point(486, 184)
$lblType.AutoSize = $true

$cmbType = New-Object System.Windows.Forms.ComboBox
$cmbType.Location = New-Object System.Drawing.Point(600, 180)
$cmbType.Size = New-Object System.Drawing.Size(190, 24)
$cmbType.DropDownStyle = 'DropDown'
foreach ($t in @('', 'azurerm', 'github', 'kubernetes', 'dockerregistry', 'externaltfs', 'git')) {
    [void]$cmbType.Items.Add($t)
}
$cmbType.SelectedIndex = 0

# ── Action buttons ────────────────────────────────────────────────────────────
$btnSearch = New-Object System.Windows.Forms.Button
$btnSearch.Text = 'Search'
$btnSearch.Location = New-Object System.Drawing.Point(810, 110)
$btnSearch.Size = New-Object System.Drawing.Size(120, 30)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = 'Export CSV'
$btnExport.Location = New-Object System.Drawing.Point(810, 146)
$btnExport.Size = New-Object System.Drawing.Size(120, 30)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = 'Close'
$btnClose.Location = New-Object System.Drawing.Point(810, 180)
$btnClose.Size = New-Object System.Drawing.Size(120, 30)

# ── Tooltips ──────────────────────────────────────────────────────────────────
$tip = New-Object System.Windows.Forms.ToolTip
$tip.AutoPopDelay = 10000
$tip.InitialDelay  = 400
$tip.ReshowDelay   = 200
$tip.ShowAlways    = $true

$tip.SetToolTip($txtOrg,     "Azure DevOps organization URL.`nExample: https://dev.azure.com/MyOrg")
$tip.SetToolTip($txtProject, "Leave blank to search all projects in the organization.`nExample: MyProject")
$tip.SetToolTip($txtName,    "Wildcard name filter (case-insensitive).`n`n  test*      — starts with 'test'`n  *prod*     — contains 'prod'`n  sc-?       — 'sc-' followed by any single character`n  *          — match everything (default)")
$tip.SetToolTip($cmbType,    "Filter by connection type. Leave blank for all types.`nCommon values: azurerm, github, kubernetes, dockerregistry, externaltfs, git")

# ── Status bar ────────────────────────────────────────────────────────────────
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Ready.'
$lblStatus.Location = New-Object System.Drawing.Point(16, 218)
$lblStatus.AutoSize = $true

# ── Results grid ──────────────────────────────────────────────────────────────
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(16, 244)
$grid.Size = New-Object System.Drawing.Size(1170, 580)
$grid.Anchor = 'Top,Bottom,Left,Right'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = 'Fill'

$form.Controls.AddRange(@(
    $grpAuth,
    $lblOrg, $txtOrg,
    $lblProject, $txtProject, $chkAllProjects,
    $lblName, $txtName,
    $lblType, $cmbType,
    $btnSearch, $btnExport, $btnClose,
    $lblStatus,
    $grid
))

#endregion

#region Event helpers

function Show-AuthStatus {
    if (Test-PatSet) {
        $lblAuthStatus.Text = 'Authenticated (PAT)'
        $lblAuthStatus.ForeColor = [System.Drawing.Color]::DarkGreen
    } elseif (Test-AzLogin) {
        $acct = az account show --query "user.name" -o tsv 2>$null
        $lblAuthStatus.Text = "Authenticated as $acct"
        $lblAuthStatus.ForeColor = [System.Drawing.Color]::DarkGreen
    } else {
        $lblAuthStatus.Text = 'Not authenticated'
        $lblAuthStatus.ForeColor = [System.Drawing.Color]::Firebrick
    }
}

#endregion

#region Event handlers

$radPAT.Add_CheckedChanged({
    $lblPAT.Visible = $radPAT.Checked
    $txtPAT.Visible = $radPAT.Checked
})

$chkAllProjects.Add_CheckedChanged({
    $txtProject.Enabled = -not $chkAllProjects.Checked
})

$btnLogin.Add_Click({
    try {
        Initialize-AzDevOpsExtension

        if ($radPAT.Checked) {
            $pat = $txtPAT.Text.Trim()
            if (-not $pat) {
                [System.Windows.Forms.MessageBox]::Show(
                    'Please enter a PAT token.', 'Login', 'OK', 'Warning') | Out-Null
                return
            }
            $env:AZURE_DEVOPS_EXT_PAT = $pat
            $lblStatus.Text = 'PAT token saved for this session.'

        } else {
            # Entra ID device-code flow
            $lblStatus.Text = 'Sign-in window opened. Complete the device-code flow then return here...'
            $form.Refresh()

            $tmpScript = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.ps1'
            @'
Write-Host 'Running: az login --use-device-code --allow-no-subscriptions' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Follow the instructions below:' -ForegroundColor Yellow
Write-Host '  1. Open the URL shown in your browser' -ForegroundColor Yellow
Write-Host '  2. Enter the device code displayed below' -ForegroundColor Yellow
Write-Host ''
az login --use-device-code --allow-no-subscriptions --output none
$code = $LASTEXITCODE
Write-Host ''
if ($code -ne 0) {
    Write-Host "LOGIN FAILED (exit code $code) - review the error above." -ForegroundColor Red
} else {
    Write-Host 'Login successful.' -ForegroundColor Green
}
Write-Host ''
Write-Host 'Press Enter to close this window...'
Read-Host
'@ | Set-Content -Path $tmpScript -Encoding ASCII

            Start-Process powershell -ArgumentList "-NoProfile -NoExit -File `"$tmpScript`"" -Wait
            Remove-Item $tmpScript -ErrorAction SilentlyContinue
            $lblStatus.Text = 'Login window closed.'
        }

        Show-AuthStatus
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Login Error', 'OK', 'Error') | Out-Null
    }
})

$btnLogout.Add_Click({
    try {
        if ($radPAT.Checked -or (Test-PatSet)) {
            $env:AZURE_DEVOPS_EXT_PAT = ''
            $txtPAT.Text = ''
            $lblStatus.Text = 'PAT token cleared.'
        } else {
            $lblStatus.Text = 'Signing out...'
            $form.Refresh()
            $null = az logout 2>&1
            $lblStatus.Text = 'Signed out.'
        }

        Show-AuthStatus
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Logout Error', 'OK', 'Error') | Out-Null
    }
})

$btnSearch.Add_Click({
    try {
        $org = Get-FieldValue $txtOrg
        if (-not $org) {
            [System.Windows.Forms.MessageBox]::Show(
                'Organization URL is required.', 'Validation', 'OK', 'Warning') | Out-Null
            return
        }

        # Guard: require authentication before querying
        if (-not (Test-PatSet) -and -not (Test-AzLogin)) {
            [System.Windows.Forms.MessageBox]::Show(
                "You are not authenticated.`n`nUse the Authentication section above to sign in with Entra ID or provide a PAT token.",
                'Not Authenticated', 'OK', 'Warning') | Out-Null
            return
        }

        Initialize-AzDevOpsExtension

        $namePattern = Get-FieldValue $txtName
        if (-not $namePattern) { $namePattern = '*' }

        $typeFilter = $cmbType.Text.Trim()

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $lblStatus.Text = 'Searching...'
        $form.Refresh()

        $script:currentResults = Find-ServiceConnection `
            -Org $org `
            -Project (Get-FieldValue $txtProject) `
            -SearchAllProjects $chkAllProjects.Checked `
            -NamePattern $namePattern `
            -ConnectionType $typeFilter

        $grid.DataSource = $null
        if ($script:currentResults.Count -gt 0) {
            $grid.DataSource = ConvertTo-DataTable -Objects $script:currentResults
            # Hide the raw DevOpsUrl column — used only for double-click navigation
            $grid.Columns['DevOpsUrl'].Visible = $false
            # Friendly column widths
            $grid.Columns['Project'].Width   = 160
            $grid.Columns['Name'].Width      = 280
            $grid.Columns['Type'].Width      = 110
            $grid.Columns['Url'].Width       = 300
            $grid.Columns['CreatedBy'].Width = 160
            $grid.Columns['IsReady'].Width   = 60
            $grid.Columns['IsShared'].Width  = 60
            $grid.AutoSizeColumnsMode = 'None'
        }
        $lblStatus.Text = "Found $($script:currentResults.Count) service connection(s). Double-click a row to open it in Azure DevOps."
    }
    catch {
        $lblStatus.Text = 'Search failed.'
        $msg = $_.Exception.Message
        if ($msg -match 'login command|credentials|Please run') {
            $msg = "Authentication required.`n`nUse the Authentication section to sign in with Entra ID or provide a PAT token.`n`nDetails: $msg"
        }
        [System.Windows.Forms.MessageBox]::Show($msg, 'Error', 'OK', 'Error') | Out-Null
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

$btnExport.Add_Click({
    if (-not $script:currentResults -or $script:currentResults.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            'No results to export.', 'Export', 'OK', 'Information') | Out-Null
        return
    }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $dialog.FileName = 'service-connections.csv'
    $dialog.Title = 'Export Search Results'

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $script:currentResults | Export-Csv -Path $dialog.FileName -NoTypeInformation -Encoding UTF8
            [System.Windows.Forms.MessageBox]::Show(
                'Export completed successfully.', 'Export', 'OK', 'Information') | Out-Null
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Export Error', 'OK', 'Error') | Out-Null
        }
    }
})

$grid.Add_CellDoubleClick({
    param($eventSender, $e)
    $null = $eventSender  # sender argument not needed
    if ($e.RowIndex -ge 0) {
        $url = $grid.Rows[$e.RowIndex].Cells['DevOpsUrl'].Value
        if ($url) { Start-Process $url }
    }
})

$grid.Add_SelectionChanged({
    if ($grid.SelectedRows.Count -gt 0) {
        $url = $grid.SelectedRows[0].Cells['DevOpsUrl'].Value
        if ($url) { $lblStatus.Text = "Double-click to open in Azure DevOps: $url" }
    }
})

$btnClose.Add_Click({
    $form.Close()
})

$form.Add_FormClosing({
    # Clear PAT from environment
    if ($env:AZURE_DEVOPS_EXT_PAT) {
        $env:AZURE_DEVOPS_EXT_PAT = ''
    }
    # Sign out of Entra ID if logged in
    if (Test-AzLogin) {
        $null = az logout 2>&1
    }
})

# Seed auth status indicator when the form first becomes visible
$form.Add_Shown({ Show-AuthStatus })

#endregion

$script:currentResults = @()
[void]$form.ShowDialog()
