#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    # Prevent the script's Invoke-Main from firing when we dot-source it.
    $env:WBT_SKIP_MAIN = '1'
    $scriptPath = Join-Path $PSScriptRoot '..' 'Get-WindowsCumulativeUpdate.ps1' | Resolve-Path
    . $scriptPath

    # Frozen sample database covering a variety of edge cases.
    $script:Db = [PSCustomObject]@{
        updatedAt = '2026-04-01T00:00:00Z'
        buildCount = 7
        builds = @(
            [PSCustomObject]@{ build='26100.6899'; major=26100; year=2025; month=10; type='Standard'; kb='KB5044284' },
            [PSCustomObject]@{ build='26100.6901'; major=26100; year=2025; month=10; type='OOB';      kb='KB5044285' },
            [PSCustomObject]@{ build='26100.7019'; major=26100; year=2025; month=10; type='Preview';  kb='KB5044286' },
            [PSCustomObject]@{ build='26100.7623'; major=26100; year=2026; month=1;  type='Standard'; kb='KB5074109' },
            [PSCustomObject]@{ build='22631.5840'; major=22631; year=2025; month=8;  type='Standard'; kb='KB5041587' },
            [PSCustomObject]@{ build='22631.6133'; major=22631; year=2025; month=10; type='Standard'; kb='KB5044285' },
            [PSCustomObject]@{ build='19045.5796'; major=19045; year=2025; month=4;  type='Standard'; kb='KB5036892' }
        )
    }
}

Describe 'Resolve-BuildInfo' {
    It 'finds an exact match' {
        $r = Resolve-BuildInfo -BuildNumber '26100.6899' -Database $script:Db
        $r.major | Should -Be 26100
        $r.type  | Should -Be 'Standard'
    }

    It 'returns $null for an unknown build' {
        Resolve-BuildInfo -BuildNumber '99999.9999' -Database $script:Db | Should -BeNullOrEmpty
    }

    It 'matches Preview entries' {
        (Resolve-BuildInfo -BuildNumber '26100.7019' -Database $script:Db).type | Should -Be 'Preview'
    }
}

Describe 'Get-LatestForFamily' {
    It 'returns the newest Standard build in the family' {
        $r = Get-LatestForFamily -Major 26100 -Database $script:Db
        $r.build | Should -Be '26100.7623'
        $r.type  | Should -Be 'Standard'
    }

    It 'ignores Preview and OOB when selecting latest' {
        # 26100.7019 (Preview) and 26100.6901 (OOB) must not be returned.
        $r = Get-LatestForFamily -Major 26100 -Database $script:Db
        $r.type | Should -Be 'Standard'
    }

    It 'returns $null for an unknown family' {
        Get-LatestForFamily -Major 99999 -Database $script:Db | Should -BeNullOrEmpty
    }

    It 'handles a family with a single Standard entry' {
        $r = Get-LatestForFamily -Major 19045 -Database $script:Db
        $r.build | Should -Be '19045.5796'
    }
}

Describe 'Get-MonthsBehind' {
    It 'returns 0 when machine is on latest' {
        $machine = $script:Db.builds | Where-Object build -eq '26100.7623'
        $latest  = $script:Db.builds | Where-Object build -eq '26100.7623'
        Get-MonthsBehind -MachineEntry $machine -LatestEntry $latest | Should -Be 0
    }

    It 'returns a negative number when behind' {
        $machine = $script:Db.builds | Where-Object build -eq '26100.6899'  # 2025-10
        $latest  = $script:Db.builds | Where-Object build -eq '26100.7623'  # 2026-01
        Get-MonthsBehind -MachineEntry $machine -LatestEntry $latest | Should -Be -3
    }

    It 'clamps future builds to 0' {
        $machine = $script:Db.builds | Where-Object build -eq '26100.7623'  # 2026-01
        $latest  = $script:Db.builds | Where-Object build -eq '26100.6899'  # 2025-10
        Get-MonthsBehind -MachineEntry $machine -LatestEntry $latest | Should -Be 0
    }

    It 'handles year-boundary correctly' {
        $machine = $script:Db.builds | Where-Object build -eq '22631.5840'  # 2025-08
        $latest  = $script:Db.builds | Where-Object build -eq '26100.7623'  # 2026-01
        Get-MonthsBehind -MachineEntry $machine -LatestEntry $latest | Should -Be -5
    }
}

Describe 'Format-DateString' {
    It 'formats a Standard entry as YYYY.MM' {
        $e = $script:Db.builds | Where-Object build -eq '26100.6899'
        Format-DateString -Entry $e | Should -Be '2025.10'
    }

    It 'appends -Preview for Preview entries' {
        $e = $script:Db.builds | Where-Object build -eq '26100.7019'
        Format-DateString -Entry $e | Should -Be '2025.10-Preview'
    }

    It 'appends -OOB for OOB entries' {
        $e = $script:Db.builds | Where-Object build -eq '26100.6901'
        Format-DateString -Entry $e | Should -Be '2025.10-OOB'
    }

    It 'zero-pads single-digit months' {
        $e = $script:Db.builds | Where-Object build -eq '26100.7623'  # 2026-01
        Format-DateString -Entry $e | Should -Be '2026.01'
    }
}
