#!powershell
# This file is part of Ansible
#
# (c) 2015, Adam Keech <akeech@chathamfinancial.com>, Josh Ludwig <jludwig@chathamfinancial.com>
#
# Ansible is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Ansible is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Ansible.  If not, see <http://www.gnu.org/licenses/>.

# WANT_JSON
# POWERSHELL_COMMON

# TODO: Add missing REG_NONE support

$ErrorActionPreference = "Stop"

$params = Parse-Args $args -supports_check_mode $true
$check_mode = Get-AnsibleParam -obj $params -name "_ansible_check_mode" -type "bool" -default $false

$path = Get-AnsibleParam -obj $params -name "path" -type "string" -failifempty $true -aliases "key"
$name = Get-AnsibleParam -obj $params -name "name" -type "string" -aliases "entry","value"
$data = Get-AnsibleParam -obj $params -name "data"
$type = Get-AnsibleParam -obj $params -name "type" -type "string" -validateSet "binary","dword","expandstring","multistring","string","qword" -aliases "datatype" -default "string"
$state = Get-AnsibleParam -obj $params -name "state" -type "string" -validateSet "present","absent" -default "present"

$result = @{
    changed = $false
    data_changed = $false
    data_type_changed = $false
    diff = @{
        prepared = ""
    }
    warnings = @()
}

if ($state -eq "present" -and $data -eq $null -and $name -ne $null) {
    Fail-Json $result "missing required argument: data"
}

# Fix HCCC:\ PSDrive for pre-2.3 compatibility
if ($path -match "^HCCC:\\") {
    $result.warnings += "Please use path: HKCC:\... instead of path: $path\n"
    $path = $path -replace "HCCC:\\","HKCC:\\"
}

# Check that the registry path is in PSDrive format: HKCC, HKCR, HKCU, HKLM, HKU
if (-not ($path -match "^HK(CC|CR|CU|LM|U):\\")) {
    Fail-Json $result "path: $path is not a valid powershell path, see module documentation for examples."
} 

# Allow empty values as the "(default)" value
if ($name -eq "") {
    $registryValue = "(default)"
}

Function Test-ValueData {
    Param (
        [parameter(Mandatory=$true)] [ValidateNotNullOrEmpty()] $Path,
        [parameter(Mandatory=$true)] [ValidateNotNullOrEmpty()] $Name
    )

    try {
        Get-ItemProperty -Path $Path -Name $Name
        return $true
    } catch {
        return $false
    }
}

# Returns true if registry data matches.
# Handles binary, integer(dword) and string registry data
Function Compare-Data {
    Param (
        [parameter(Mandatory=$true)] [AllowEmptyString()] $ReferenceData,
        [parameter(Mandatory=$true)] [AllowEmptyString()] $DifferenceData
    )

    if ($ReferenceData -is [String] -or $ReferenceData -is [int]) {
        if ($ReferenceData -eq $DifferenceData) {
            return $true
        } else {
            return $false
        }
    } elseif ($ReferenceData -is [Object[]]) {
        if (@(Compare-Object $ReferenceData $DifferenceData -SyncWindow 0).Length -eq 0) {
            return $true
        } else {
            return $false
        }
    }
}

# Simplified version of Convert-HexStringToByteArray from
# https://cyber-defense.sans.org/blog/2010/02/11/powershell-byte-array-hex-convert
# Expects a hex in the format you get when you run reg.exe export,
# and converts to a byte array so powershell can modify binary registry entries
function Convert-RegExportHexStringToByteArray {
    Param (
        [parameter(Mandatory=$true)] [String] $String
    )

    # Remove 'hex:' from the front of the string if present
    $String = $String.ToLower() -replace '^hex\:',''

    # Remove whitespace and any other non-hex crud.
    $String = $String.ToLower() -replace '[^a-f0-9\\,x\-\:]',''

    # Turn commas into colons
    $String = $String -replace ',',':'

    # Maybe there's nothing left over to convert...
    if ($String.Length -eq 0) {
        return ,@()
    }

    # Split string with or without colon delimiters.
    if ($String.Length -eq 1) {
        return ,@([System.Convert]::ToByte($String,16))
    } elseif (($String.Length % 2 -eq 0) -and ($String.IndexOf(":") -eq -1)) {
        return ,@($String -split '([a-f0-9]{2})' | foreach-object { if ($_) {[System.Convert]::ToByte($_,16)}})
    } elseif ($String.IndexOf(":") -ne -1) {
        return ,@($String -split ':+' | foreach-object {[System.Convert]::ToByte($_,16)})
    } else {
        return ,@()
    }
}

# Create the required PSDrives if missing
if (-not (Test-Path HKCR:\)) {
    New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT
}
if (-not (Test-Path HKU:\)) {
    New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS
}
if (-not (Test-Path HKCC:\)) {
    New-PSDrive -Name HKCC -PSProvider Registry -Root HKEY_CURRENT_CONFIG
}

# Convert HEX string to binary if type binary
if ($type -eq "binary" -and $data -ne $null -and $data -is [String]) {
    $data = Convert-RegExportHexStringToByteArray($data)
}

# Expand string if type expandstring
if ($type -eq "expandstring" -and $data -ne $null -and $data -is [String]) {
    $data = Expand-Environment($data)
    $datatype = "string"
}

if ($state -eq "present") {

    if ((Test-Path $path) -and $name -ne $null) {

        if (Test-ValueData -Path $path -Name $name) {

            # Handle binary data
            $old_data =(Get-ItemProperty -Path $path | Select-Object -ExpandProperty $name)

            if ($name.ToLower() -eq "(default)") {
                # Special case handling for the path's default property.
                # Because .GetValueKind() doesn't work for the (default) path property
                $old_type = "String"
            } else {
                $old_type = (Get-Item $path).GetValueKind($name)
            }

            if ($type -ne $old_type) {
                # Changes Data and DataType
                if (-not $check_mode) {
                    try {
                        Remove-ItemProperty -Path $path -Name $name
                        New-ItemProperty -Path $path -Name $name -Value $data -PropertyType $type -Force
                    } catch {
                        Fail-Json $result $_.Exception.Message
                    }
                }
                $result.changed = $true
                $result.data_changed = $true
                $result.data_type_changed = $true
                $result.diff.prepared += @"
 [$path]
-"$name" = "$old_type`:$data"
+"$name" = "$type`:$data"
"@

            } elseif (-not (Compare-Data -ReferenceData $old_data -DifferenceData $data)) {
                # Changes Only Data
                if (-not $check_mode) {
                    try {
                        Set-ItemProperty -Path $path -Name $name -Value $data
                    } catch {
                        Fail-Json $result $_.Exception.Message
                    }
                }
                $result.changed = $true
                $result.data_changed = $true
                $result.diff.prepared += @"
 [$path]
-"$name" = "$type`:$old_data"
+"$name" = "$type`:$data"
"@

            } else {
                # Nothing to do, everything is already as requested
            }

        } else {

            if (-not $check_mode) {
                try {
                    New-ItemProperty -Path $path -Name $name -Value $data -PropertyType $type
                } Catch {
                    Fail-Json $result $_.Exception.Message
                }
            }
            $result.changed = $true
            $result.diff.prepared += @"
 [$path]
+"$name" = "$type`:$data"
"@
        }

    } elseif (-not (Test-Path $path)) {

        if (-not $check_mode) {
            try {
                $new_path = New-Item $path -Type directory -Force
                if ($name -ne $null) {
                    $new_path | New-ItemProperty -Name $name -Value $data -PropertyType $type -Force
                }
            } catch {
                throw
                Fail-Json $result $_.Exception.Message
            }
        }
        $result.changed = $true
        $result.diff.prepared += @"
+[$path"]

"@
        if ($name -ne $null) {
            $result.diff.prepared += @"
+"$name" = "$type`:$data"

"@
        }

    } else {
        # FIXME: Value is null, should we silently ignore this and do nothing ?
    }

} elseif ($state -eq "absent") {

    if (Test-Path $path) {
        if ($name -eq $null) {

            if (-not $check_mode) {
                try {
                    Remove-Item -Path $path -Recurse
                } catch {
                    Fail-Json $result $_.Exception.Message
                }
            }
            $result.changed = $true
            $result.diff.prepared += @"
-[$path]
-"$name" = "$type`:$data"
"@

        } elseif (Test-ValueData -Path $path -Value $name) {

            if (-not $check_mode) {
                try {
                    Remove-ItemProperty -Path $path -Name $name
                } catch {
                    Fail-Json $result $_.Exception.Message
                }
            }
            $result.changed = $true
            $result.diff.prepared += @"
 [$path]
-"$name" = "$type`:$data"
"@
        }
    } else {
        # Nothing to do, everything is already as requested
    }
}

Exit-Json $result
