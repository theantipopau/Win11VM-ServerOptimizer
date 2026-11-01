@{
    # Used by .github/workflows/ci.yml and by hand:
    #   Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # These are interactive console tools: coloured Write-Host output is the intended UX, and
        # the log file already captures everything worth capturing for automation.
        'PSAvoidUsingWriteHost'

        # The -DryRun / -Force switch pair is a deliberate choice over ShouldProcess: -WhatIf would
        # be skipped by Invoke-Action's own dry-run branch, and the scripts need a single, honest
        # code path that either applies changes or reports exactly what it would have done.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
