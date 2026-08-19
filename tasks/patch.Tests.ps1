#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x coverage for patchbot::patch's Windows implementation
    (patch.ps1) -- mirrors patch.sh's own patch_test.sh test contract
    (02-01-PLAN.md Task 1) plus D-03's fuller Pester scope: dry-run/search,
    the reboot flag, the SecurityOnly filter, and PatchIds membership.

.DESCRIPTION
    Never executed against a live pwsh/Pester install during this phase --
    no Windows/pwsh runtime exists in this dev environment (02-RESEARCH.md's
    Environment Availability table). Written from Pester 5.x Describe/
    Context/It/Mock conventions; verify + fix any syntax mismatches on a
    real Windows host per 02-01-PLAN.md Task 3's checkpoint. Do NOT change
    the underlying assertions' intent when fixing syntax there.

    patch.ps1 is a top-level script (not a module) that calls `exit 0` from
    three places after this plan's GREEN step (FailJson's two call sites,
    plus the pre-existing reboot-now branch). `exit` cannot be caught by
    try/catch and cannot be shadowed by a same-named function -- it always
    terminates the current PowerShell runspace. Three strategies are used
    here to work around that safely:

      1. Pure-function tests (Test-IsSecurityUpdate, Get-UpdateId) load
         ONLY those function definitions via AST extraction, never running
         patch.ps1's top-level body at all -- safe to dot-source directly,
         no exit risk.

      2. Full-script tests that do NOT hit an exit call (patch_ids
         membership, SecurityOnly filtering, the plain success shape) use
         Pester's own `Mock New-Object` and dot-source patch.ps1 directly
         in the current runspace.

      3. Full-script tests that DO hit `exit 0` (search failure, install
         failure, reboot-required-true) run patch.ps1 inside an isolated
         Start-Job background runspace, so `exit` only terminates the job's
         runspace, not the Pester process itself. Pester's `Mock` cannot
         reach into a separate job runspace, so these three cases shadow
         New-Object with a plain function defined inside the job
         scriptblock instead (same interception idea, different plumbing).
#>

BeforeAll {
    $Script:PatchScriptPath    = Join-Path $PSScriptRoot 'patch.ps1'
    $Script:PatchScriptContent = Get-Content -Path $Script:PatchScriptPath -Raw

    # --- Strategy 1: isolate the pure helper functions --------------------
    $tokens      = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Script:PatchScriptContent, [ref]$tokens, [ref]$parseErrors)
    $functionAsts = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true)
    foreach ($fnAst in $functionAsts) {
        . ([scriptblock]::Create($fnAst.Extent.Text))
    }

    # --- Fake WUA object graph (Strategy 2) --------------------------------
    function New-FakeUpdate {
        param(
            [string]$UpdateId,
            [string[]]$KBArticleIDs = @(),
            [bool]$IsSecurity = $false,
            [bool]$EulaAccepted = $true
        )
        $categories = @()
        if ($IsSecurity) {
            $categories = @([pscustomobject]@{ Name = 'Security Updates' })
        }
        $update = [pscustomobject]@{
            Identity     = [pscustomobject]@{ UpdateID = $UpdateId }
            KBArticleIDs = $KBArticleIDs
            MsrcSeverity = $(if ($IsSecurity) { 'Critical' } else { $null })
            Categories   = $categories
            EulaAccepted = $EulaAccepted
        }
        $update | Add-Member -MemberType ScriptMethod -Name AcceptEula -Value { } -Force
        return $update
    }

    function New-FakeUpdateColl {
        $items = [System.Collections.ArrayList]::new()
        $coll = [pscustomobject]@{}
        $coll | Add-Member -MemberType ScriptMethod -Name Add -Value {
            param($u)
            $items.Add($u) | Out-Null
        } -Force
        $coll | Add-Member -MemberType ScriptProperty -Name Count -Value {
            $items.Count
        } -Force
        return $coll
    }

    function New-FakeSession {
        param(
            [object[]]$Updates = @()
        )
        $searchResult = [pscustomobject]@{ Updates = $Updates }
        $searcher = [pscustomobject]@{}
        $searcher | Add-Member -MemberType ScriptMethod -Name Search -Value {
            param($criteria)
            return $searchResult
        } -Force

        $installResult = [pscustomobject]@{ RebootRequired = $false }
        $installer = [pscustomobject]@{ Updates = $null }
        $installer | Add-Member -MemberType ScriptMethod -Name Install -Value {
            return $installResult
        } -Force

        $downloader = [pscustomobject]@{ Updates = $null }
        $downloader | Add-Member -MemberType ScriptMethod -Name Download -Value { } -Force

        $session = [pscustomobject]@{}
        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher -Value {
            return $searcher
        } -Force
        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateDownloader -Value {
            return $downloader
        } -Force
        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateInstaller -Value {
            return $installer
        } -Force

        return $session
    }
}

AfterEach {
    Remove-Item Env:\PT_patch_ids -ErrorAction SilentlyContinue
    Remove-Item Env:\PT_security_only -ErrorAction SilentlyContinue
    Remove-Item Env:\PT_reboot -ErrorAction SilentlyContinue
}

Describe 'patch.ps1' {

    Context 'Test-IsSecurityUpdate (pure function)' {
        It 'returns $true when MsrcSeverity is set' {
            $u = [pscustomobject]@{ MsrcSeverity = 'Important'; Categories = @() }
            Test-IsSecurityUpdate $u | Should -BeTrue
        }

        It 'returns $true when a Categories entry is named "Security Updates"' {
            $u = [pscustomobject]@{
                MsrcSeverity = $null
                Categories   = @([pscustomobject]@{ Name = 'Security Updates' })
            }
            Test-IsSecurityUpdate $u | Should -BeTrue
        }

        It 'returns $false when neither MsrcSeverity nor a Security Updates category is present' {
            $u = [pscustomobject]@{
                MsrcSeverity = $null
                Categories   = @([pscustomobject]@{ Name = 'Feature Packs' })
            }
            Test-IsSecurityUpdate $u | Should -BeFalse
        }
    }

    Context 'Get-UpdateId (pure function)' {
        It 'returns "KB"+n when KBArticleIDs is populated' {
            $u = [pscustomobject]@{
                KBArticleIDs = @('5001234')
                Identity     = [pscustomobject]@{ UpdateID = 'ignored-guid' }
            }
            Get-UpdateId $u | Should -Be 'KB5001234'
        }

        It 'falls back to Identity.UpdateID when KBArticleIDs is empty' {
            $u = [pscustomobject]@{
                KBArticleIDs = @()
                Identity     = [pscustomobject]@{ UpdateID = 'guid-fallback' }
            }
            Get-UpdateId $u | Should -Be 'guid-fallback'
        }
    }

    Context 'patch_ids membership filtering (full script, Mock)' {
        It 'installs only the mocked updates whose id matches PT_patch_ids' {
            $matchUpdate = New-FakeUpdate -UpdateId 'guid-1' -KBArticleIDs @('5001111')
            $otherUpdate = New-FakeUpdate -UpdateId 'guid-2' -KBArticleIDs @('5002222')
            $Script:installedIdsCapture = [System.Collections.ArrayList]::new()

            Mock New-Object {
                if ($ComObject -eq 'Microsoft.Update.Session') {
                    return (New-FakeSession -Updates @($matchUpdate, $otherUpdate))
                }
                if ($ComObject -eq 'Microsoft.Update.UpdateColl') {
                    $coll = New-FakeUpdateColl
                    $coll | Add-Member -MemberType ScriptMethod -Name Add -Value {
                        param($u)
                        $Script:installedIdsCapture.Add((Get-UpdateId $u)) | Out-Null
                    } -Force
                    return $coll
                }
                if ($ComObject -eq 'Microsoft.Update.SystemInfo') {
                    return [pscustomobject]@{ RebootRequired = $false }
                }
            } -ParameterFilter { $ComObject }

            $env:PT_patch_ids = '["KB5001111"]'

            . $Script:PatchScriptPath | Out-Null

            $Script:installedIdsCapture | Should -Contain 'KB5001111'
            $Script:installedIdsCapture | Should -Not -Contain 'KB5002222'
        }
    }

    Context 'SecurityOnly filtering (full script, Mock)' {
        It 'selects only mocked updates flagged as security when PT_security_only=true and no patch_ids' {
            $securityUpdate = New-FakeUpdate -UpdateId 'guid-sec' -IsSecurity $true
            $normalUpdate   = New-FakeUpdate -UpdateId 'guid-normal' -IsSecurity $false
            $Script:installedIdsCapture = [System.Collections.ArrayList]::new()

            Mock New-Object {
                if ($ComObject -eq 'Microsoft.Update.Session') {
                    return (New-FakeSession -Updates @($securityUpdate, $normalUpdate))
                }
                if ($ComObject -eq 'Microsoft.Update.UpdateColl') {
                    $coll = New-FakeUpdateColl
                    $coll | Add-Member -MemberType ScriptMethod -Name Add -Value {
                        param($u)
                        $Script:installedIdsCapture.Add($u.Identity.UpdateID) | Out-Null
                    } -Force
                    return $coll
                }
                if ($ComObject -eq 'Microsoft.Update.SystemInfo') {
                    return [pscustomobject]@{ RebootRequired = $false }
                }
            } -ParameterFilter { $ComObject }

            $env:PT_security_only = 'true'

            . $Script:PatchScriptPath | Out-Null

            $Script:installedIdsCapture | Should -Contain 'guid-sec'
            $Script:installedIdsCapture | Should -Not -Contain 'guid-normal'
        }
    }

    Context 'success path shape (full script, Mock, regression)' {
        It 'emits {"status":"patched","applied":...,"reboot_required":...,"rebooted":false}' {
            Mock New-Object {
                if ($ComObject -eq 'Microsoft.Update.Session') {
                    return (New-FakeSession -Updates @())
                }
                if ($ComObject -eq 'Microsoft.Update.UpdateColl') {
                    return (New-FakeUpdateColl)
                }
                if ($ComObject -eq 'Microsoft.Update.SystemInfo') {
                    return [pscustomobject]@{ RebootRequired = $false }
                }
            } -ParameterFilter { $ComObject }

            $out  = . $Script:PatchScriptPath
            $json = ($out | Select-Object -Last 1) | ConvertFrom-Json

            $json.status  | Should -Be 'patched'
            $json.applied | Should -Be 'all'
            $json.rebooted | Should -Be $false
        }
    }

    Context 'business-logic failures embed FailJson and exit 0 (isolated job)' {
        It 'emits {"status":"error","error":"update search failed: ..."} when WUA search throws' {
            $job = Start-Job -ScriptBlock {
                param($ScriptPath)
                function New-Object {
                    param([string]$ComObject, [string]$TypeName)
                    if ($ComObject -eq 'Microsoft.Update.Session') {
                        $searcher = [pscustomobject]@{}
                        $searcher | Add-Member -MemberType ScriptMethod -Name Search -Value {
                            param($criteria)
                            throw 'simulated WUA search failure'
                        } -Force
                        $session = [pscustomobject]@{}
                        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher -Value {
                            return $searcher
                        } -Force
                        return $session
                    }
                    if ($ComObject -eq 'Microsoft.Update.UpdateColl') {
                        $items = [System.Collections.ArrayList]::new()
                        $coll = [pscustomobject]@{}
                        $coll | Add-Member -MemberType ScriptMethod -Name Add -Value { param($u) $items.Add($u) | Out-Null } -Force
                        $coll | Add-Member -MemberType ScriptProperty -Name Count -Value { $items.Count } -Force
                        return $coll
                    }
                    Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
                }
                . $ScriptPath
            } -ArgumentList $Script:PatchScriptPath

            $out = $job | Wait-Job | Receive-Job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force

            $json = ($out -join "`n") | ConvertFrom-Json
            $json.status | Should -Be 'error'
            $json.error  | Should -Match '^update search failed:'
        }

        It 'emits {"status":"error","error":"update install failed: ..."} when install throws' {
            $updateId = 'guid-install-fail'

            $job = Start-Job -ScriptBlock {
                param($ScriptPath, $UpdateId)
                function New-Object {
                    param([string]$ComObject, [string]$TypeName)
                    if ($ComObject -eq 'Microsoft.Update.Session') {
                        $update = [pscustomobject]@{
                            Identity     = [pscustomobject]@{ UpdateID = $UpdateId }
                            KBArticleIDs = @()
                            MsrcSeverity = $null
                            Categories   = @()
                            EulaAccepted = $true
                        }
                        $update | Add-Member -MemberType ScriptMethod -Name AcceptEula -Value { } -Force

                        $searcher = [pscustomobject]@{}
                        $searcher | Add-Member -MemberType ScriptMethod -Name Search -Value {
                            param($criteria)
                            return [pscustomobject]@{ Updates = @($update) }
                        } -Force

                        $downloader = [pscustomobject]@{ Updates = $null }
                        $downloader | Add-Member -MemberType ScriptMethod -Name Download -Value { } -Force

                        $installer = [pscustomobject]@{ Updates = $null }
                        $installer | Add-Member -MemberType ScriptMethod -Name Install -Value {
                            throw 'simulated WUA install failure'
                        } -Force

                        $session = [pscustomobject]@{}
                        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher -Value { return $searcher } -Force
                        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateDownloader -Value { return $downloader } -Force
                        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateInstaller -Value { return $installer } -Force
                        return $session
                    }
                    if ($ComObject -eq 'Microsoft.Update.UpdateColl') {
                        $items = [System.Collections.ArrayList]::new()
                        $coll = [pscustomobject]@{}
                        $coll | Add-Member -MemberType ScriptMethod -Name Add -Value { param($u) $items.Add($u) | Out-Null } -Force
                        $coll | Add-Member -MemberType ScriptProperty -Name Count -Value { $items.Count } -Force
                        return $coll
                    }
                    Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
                }
                . $ScriptPath
            } -ArgumentList $Script:PatchScriptPath, $updateId

            $out = $job | Wait-Job | Receive-Job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force

            $json = ($out -join "`n") | ConvertFrom-Json
            $json.status | Should -Be 'error'
            $json.error  | Should -Match '^update install failed:'
        }
    }

    Context 'reboot flag (isolated job)' {
        It 'emits "rebooting": true without erroring when PT_reboot=true and rebootRequired=$true' {
            $job = Start-Job -ScriptBlock {
                param($ScriptPath)
                $env:PT_reboot = 'true'

                function New-Object {
                    param([string]$ComObject, [string]$TypeName)
                    if ($ComObject -eq 'Microsoft.Update.Session') {
                        $searcher = [pscustomobject]@{}
                        $searcher | Add-Member -MemberType ScriptMethod -Name Search -Value {
                            param($criteria)
                            return [pscustomobject]@{ Updates = @() }
                        } -Force

                        $downloader = [pscustomobject]@{ Updates = $null }
                        $downloader | Add-Member -MemberType ScriptMethod -Name Download -Value { } -Force

                        $installer = [pscustomobject]@{ Updates = $null }
                        $installer | Add-Member -MemberType ScriptMethod -Name Install -Value {
                            return [pscustomobject]@{ RebootRequired = $true }
                        } -Force

                        $session = [pscustomobject]@{}
                        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher -Value { return $searcher } -Force
                        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateDownloader -Value { return $downloader } -Force
                        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateInstaller -Value { return $installer } -Force
                        return $session
                    }
                    if ($ComObject -eq 'Microsoft.Update.UpdateColl') {
                        $items = [System.Collections.ArrayList]::new()
                        $coll = [pscustomobject]@{}
                        $coll | Add-Member -MemberType ScriptMethod -Name Add -Value { param($u) $items.Add($u) | Out-Null } -Force
                        $coll | Add-Member -MemberType ScriptProperty -Name Count -Value { $items.Count } -Force
                        return $coll
                    }
                    if ($ComObject -eq 'Microsoft.Update.SystemInfo') {
                        return [pscustomobject]@{ RebootRequired = $true }
                    }
                    Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
                }

                # Never actually reboot the isolated job's host.
                function Start-Process { param([string]$FilePath, [string[]]$ArgumentList) }

                . $ScriptPath
            } -ArgumentList $Script:PatchScriptPath

            $out = $job | Wait-Job | Receive-Job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force

            $json = ($out -join "`n") | ConvertFrom-Json
            $json.status          | Should -Be 'patched'
            $json.reboot_required | Should -Be $true
            $json.rebooting       | Should -Be $true
        }
    }
}
