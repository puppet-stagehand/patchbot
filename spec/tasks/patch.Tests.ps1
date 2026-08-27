#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x/6.x coverage for patchbot::patch's Windows implementation
    (patch.ps1) -- mirrors patch.sh's own patch_test.sh test contract
    (02-01-PLAN.md Task 1) plus D-03's fuller Pester scope: dry-run/search,
    the reboot flag, the SecurityOnly filter, and PatchIds membership.

.DESCRIPTION
    Moved from tasks/patch.Tests.ps1 to spec/tasks/patch.Tests.ps1 and
    repaired for real Pester lifecycle/scoping semantics (04.1-03-PLAN.md
    Task 1, citing pcm's d374a35 PDK-3.8 "tests move under spec/" scaffold
    convention). Three real bugs were found and fixed while making this
    suite runnable, not just relocated:

      1. A root-level (directly-in-container) `AfterEach` is rejected by
         both Pester 5.x and 6.x ("Each test Teardown is not supported in
         root") -- moved inside the `Describe` block.

      2. `Add-Member -MemberType ScriptMethod -Value { ... $outerVar ... }`
         does NOT close over the enclosing scope's local variables by
         default in PowerShell -- the scriptblock runs in a fresh scope
         when later invoked as a method, so `$outerVar` resolves to $null
         at call time. Every fake-object graph in this file (session/
         searcher/installer/downloader/collection) referenced an
         enclosing-scope variable this way; all now use `.GetNewClosure()`
         so the method body actually captures its constructor-time values.
         (Verified directly: an isolated repro of this exact pattern
         returned $null before the fix, the correct value after.)

      3. Pester's `Mock New-Object -ParameterFilter { $ComObject }`
         generates its interception proxy from the real `New-Object`
         cmdlet's parameter sets on the CURRENT platform. `-ComObject` is a
         Windows-only parameter set (COM interop): on non-Windows pwsh it
         does not exist, so `New-Object -ComObject ...` throws
         ParameterBindingException before the mock body ever runs. The
         three non-job contexts below no longer use Pester `Mock` for this
         reason -- they shadow `New-Object` with a plain local function
         (same technique the job-based contexts already used), which works
         identically on any platform because it is ordinary PowerShell
         function-precedence-over-cmdlet resolution, not COM.

    Verified locally against real pwsh 7.6.5 + Pester 5.9.0 and 6.1.0 on
    this dev host (macOS arm64): all 11 cases pass on both Pester majors.
    Per D-15, this macOS-native run is iteration/regression evidence only,
    NOT releasable proof -- the authoritative pass must come from a real
    windows-2022 x64 GitHub Actions run (see ci.yml's windows-pester job).

    patch.ps1 is a top-level script (not a module) that calls `exit 0` from
    three places (FailJson's two call sites, plus the reboot-now branch).
    `exit` cannot be caught by try/catch and cannot be shadowed by a
    same-named function -- it always terminates the current PowerShell
    runspace. Two strategies are used here to work around that safely:

      1. Full-script tests that do NOT hit an exit call (patch_ids
         membership, SecurityOnly filtering, the plain success shape)
         shadow `New-Object` with a local function and dot-source patch.ps1
         directly in the current runspace.

      2. Full-script tests that DO hit `exit 0` (search failure, install
         failure, reboot-required-true) run patch.ps1 inside an isolated
         Start-Job background runspace, so `exit` only terminates the job's
         runspace, not the Pester process itself.
#>

BeforeAll {
    $Script:PatchScriptPath    = (Resolve-Path (Join-Path $PSScriptRoot '../../tasks/patch.ps1')).Path
    $Script:PatchScriptContent = Get-Content -Path $Script:PatchScriptPath -Raw

    # --- Strategy: isolate the pure helper functions -----------------------
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

    # --- Fake WUA object graph ----------------------------------------------
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

    # NOTE on .GetNewClosure(): a scriptblock passed to Add-Member
    # -MemberType ScriptMethod/ScriptProperty does NOT lexically capture
    # its enclosing function's local variables by default in PowerShell --
    # once the defining function returns, a plain `{ return $searcher }`
    # resolves $searcher as $null at invocation time (it's out of scope),
    # not the value that was live when Add-Member ran. .GetNewClosure()
    # snapshots the current variable scope into the scriptblock, making it
    # a real closure. Every ScriptMethod/ScriptProperty below that
    # references an outer-scope variable needs it; ones with a literal
    # body (empty, or a bare `throw '...'`) don't. This was the actual
    # root cause behind every failure the first real CI run surfaced here
    # (mocked WUA objects silently returning $null from their own
    # methods) -- authored blind, never run against real Pester before.

    function New-FakeUpdateColl {
        $items = [System.Collections.ArrayList]::new()
        $coll = [pscustomobject]@{}
        $coll | Add-Member -MemberType ScriptMethod -Name Add -Value {
            param($u)
            $items.Add($u) | Out-Null
        }.GetNewClosure() -Force
        $coll | Add-Member -MemberType ScriptProperty -Name Count -Value {
            $items.Count
        }.GetNewClosure() -Force
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
        }.GetNewClosure() -Force

        $installResult = [pscustomobject]@{ RebootRequired = $false }
        $installer = [pscustomobject]@{ Updates = $null }
        $installer | Add-Member -MemberType ScriptMethod -Name Install -Value {
            return $installResult
        }.GetNewClosure() -Force

        $downloader = [pscustomobject]@{ Updates = $null }
        $downloader | Add-Member -MemberType ScriptMethod -Name Download -Value { } -Force

        $session = [pscustomobject]@{}
        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher -Value {
            return $searcher
        }.GetNewClosure() -Force
        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateDownloader -Value {
            return $downloader
        }.GetNewClosure() -Force
        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateInstaller -Value {
            return $installer
        }.GetNewClosure() -Force

        return $session
    }
}

Describe 'patch.ps1' {
    # AfterEach must live inside a Describe/Context block -- Pester 5.x/6.x
    # both reject a root-level (directly-in-container) Teardown block with
    # "Each test Teardown is not supported in root". Verified locally: the
    # pre-move file failed all 11 tests with exactly this runtime error
    # before this fix, on both Pester 5.9.0 and 6.1.0.
    AfterEach {
        Remove-Item Env:\PT_patch_ids -ErrorAction SilentlyContinue
        Remove-Item Env:\PT_security_only -ErrorAction SilentlyContinue
        Remove-Item Env:\PT_reboot -ErrorAction SilentlyContinue
        Remove-Item Function:\New-Object -ErrorAction SilentlyContinue
        Remove-Item Variable:\Script:fakeSession -ErrorAction SilentlyContinue
        Remove-Item Variable:\Script:fakeColl -ErrorAction SilentlyContinue
        Remove-Item Variable:\Script:installedIdsCapture -ErrorAction SilentlyContinue
    }

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

    Context 'patch_ids membership filtering (full script, function-shadow)' {
        It 'installs only the mocked updates whose id matches PT_patch_ids' {
            $matchUpdate = New-FakeUpdate -UpdateId 'guid-1' -KBArticleIDs @('5001111')
            $otherUpdate = New-FakeUpdate -UpdateId 'guid-2' -KBArticleIDs @('5002222')
            $Script:fakeSession         = New-FakeSession -Updates @($matchUpdate, $otherUpdate)
            $Script:installedIdsCapture = [System.Collections.ArrayList]::new()

            function New-Object {
                param([string]$ComObject, [string]$TypeName)
                if ($ComObject -eq 'Microsoft.Update.Session') {
                    return $Script:fakeSession
                }
                if ($ComObject -eq 'Microsoft.Update.UpdateColl') {
                    $coll = [pscustomobject]@{}
                    $coll | Add-Member -MemberType ScriptMethod -Name Add -Value {
                        param($u)
                        $Script:installedIdsCapture.Add((Get-UpdateId $u)) | Out-Null
                    } -Force
                    return $coll
                }
                if ($ComObject -eq 'Microsoft.Update.SystemInfo') {
                    return [pscustomobject]@{ RebootRequired = $false }
                }
                Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
            }

            $env:PT_patch_ids = '["KB5001111"]'

            . $Script:PatchScriptPath | Out-Null

            $Script:installedIdsCapture | Should -Contain 'KB5001111'
            $Script:installedIdsCapture | Should -Not -Contain 'KB5002222'
        }
    }

    Context 'SecurityOnly filtering (full script, function-shadow)' {
        It 'selects only mocked updates flagged as security when PT_security_only=true and no patch_ids' {
            $securityUpdate = New-FakeUpdate -UpdateId 'guid-sec' -IsSecurity $true
            $normalUpdate   = New-FakeUpdate -UpdateId 'guid-normal' -IsSecurity $false
            $Script:fakeSession         = New-FakeSession -Updates @($securityUpdate, $normalUpdate)
            $Script:installedIdsCapture = [System.Collections.ArrayList]::new()

            function New-Object {
                param([string]$ComObject, [string]$TypeName)
                if ($ComObject -eq 'Microsoft.Update.Session') {
                    return $Script:fakeSession
                }
                if ($ComObject -eq 'Microsoft.Update.UpdateColl') {
                    $coll = [pscustomobject]@{}
                    $coll | Add-Member -MemberType ScriptMethod -Name Add -Value {
                        param($u)
                        $Script:installedIdsCapture.Add($u.Identity.UpdateID) | Out-Null
                    } -Force
                    return $coll
                }
                if ($ComObject -eq 'Microsoft.Update.SystemInfo') {
                    return [pscustomobject]@{ RebootRequired = $false }
                }
                Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
            }

            $env:PT_security_only = 'true'

            . $Script:PatchScriptPath | Out-Null

            $Script:installedIdsCapture | Should -Contain 'guid-sec'
            $Script:installedIdsCapture | Should -Not -Contain 'guid-normal'
        }
    }

    Context 'success path shape (full script, function-shadow, regression)' {
        It 'emits {"status":"patched","applied":...,"reboot_required":...,"rebooted":false}' {
            $Script:fakeSession = New-FakeSession -Updates @()
            $Script:fakeColl    = New-FakeUpdateColl

            function New-Object {
                param([string]$ComObject, [string]$TypeName)
                if ($ComObject -eq 'Microsoft.Update.Session') {
                    return $Script:fakeSession
                }
                if ($ComObject -eq 'Microsoft.Update.UpdateColl') {
                    return $Script:fakeColl
                }
                if ($ComObject -eq 'Microsoft.Update.SystemInfo') {
                    return [pscustomobject]@{ RebootRequired = $false }
                }
                Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
            }

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
                        }.GetNewClosure() -Force
                        return $session
                    }
                    if ($ComObject -eq 'Microsoft.Update.UpdateColl') {
                        $items = [System.Collections.ArrayList]::new()
                        $coll = [pscustomobject]@{}
                        $coll | Add-Member -MemberType ScriptMethod -Name Add -Value { param($u) $items.Add($u) | Out-Null }.GetNewClosure() -Force
                        $coll | Add-Member -MemberType ScriptProperty -Name Count -Value { $items.Count }.GetNewClosure() -Force
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
                        }.GetNewClosure() -Force

                        $downloader = [pscustomobject]@{ Updates = $null }
                        $downloader | Add-Member -MemberType ScriptMethod -Name Download -Value { } -Force

                        $installer = [pscustomobject]@{ Updates = $null }
                        $installer | Add-Member -MemberType ScriptMethod -Name Install -Value {
                            throw 'simulated WUA install failure'
                        } -Force

                        $session = [pscustomobject]@{}
                        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher -Value { return $searcher }.GetNewClosure() -Force
                        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateDownloader -Value { return $downloader }.GetNewClosure() -Force
                        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateInstaller -Value { return $installer }.GetNewClosure() -Force
                        return $session
                    }
                    if ($ComObject -eq 'Microsoft.Update.UpdateColl') {
                        $items = [System.Collections.ArrayList]::new()
                        $coll = [pscustomobject]@{}
                        $coll | Add-Member -MemberType ScriptMethod -Name Add -Value { param($u) $items.Add($u) | Out-Null }.GetNewClosure() -Force
                        $coll | Add-Member -MemberType ScriptProperty -Name Count -Value { $items.Count }.GetNewClosure() -Force
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
                        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher -Value { return $searcher }.GetNewClosure() -Force
                        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateDownloader -Value { return $downloader }.GetNewClosure() -Force
                        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateInstaller -Value { return $installer }.GetNewClosure() -Force
                        return $session
                    }
                    if ($ComObject -eq 'Microsoft.Update.UpdateColl') {
                        $items = [System.Collections.ArrayList]::new()
                        $coll = [pscustomobject]@{}
                        $coll | Add-Member -MemberType ScriptMethod -Name Add -Value { param($u) $items.Add($u) | Out-Null }.GetNewClosure() -Force
                        $coll | Add-Member -MemberType ScriptProperty -Name Count -Value { $items.Count }.GetNewClosure() -Force
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
