# 0b_pipeline_identity.ps1 - one-time setup for the GitHub Actions pipeline.
# For each environment (dev, test, prod):
#   1. one user-assigned managed identity in THAT environment's resource group (id-ais-<region>-<workload>-cicd-<env>)
#   2. one federated credential trusting GitHub jobs that run inside the GitHub Environment of the same name. No secrets.
#   3. Foundry Owner on that resource group only (deployments + agents; nothing else is needed)
#   4. the GitHub Environment and its variables (prod gets a required reviewer)
# Requires: az login, gh auth login (repo + workflow scope), and the GitHub repo already pushed.
# Usage:  .\scripts\0b_pipeline_identity.ps1            (reviewer = the signed-in gh user)
#         .\scripts\0b_pipeline_identity.ps1 -Reviewer someone
param([string]$Reviewer = "")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Get-Content (Join-Path $root ".env") | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2; Set-Item -Path "Env:$($k.Trim())" -Value $v.Trim()
}
foreach ($k in @("AZURE_SUBSCRIPTION_ID", "GITHUB_REPO")) {
    if (-not (Get-Item "Env:$k").Value -or (Get-Item "Env:$k").Value -like "*<*") { throw "Edit .env first: $k is still a placeholder." }
}
az account set --subscription $env:AZURE_SUBSCRIPTION_ID
$sub = $env:AZURE_SUBSCRIPTION_ID
$tenant = az account show --query tenantId -o tsv
$rc = $env:REGION_CODE; $wl = $env:WORKLOAD; $repo = $env:GITHUB_REPO

# GitHub identifiers. Repos created after 2026-07-15 present the immutable OIDC subject
#   repo:OWNER@OWNER-ID/REPO@REPO-ID:environment:<name>
# so the federated credential must carry the numeric ids, not just the names.
$owner, $name = $repo -split '/', 2
$ownerId = gh api "users/$owner" --jq '.id'
$repoId = gh api "repos/$repo" --jq '.id'
if (-not $Reviewer) { $Reviewer = gh api user --jq '.login' }
$reviewerId = gh api "users/$Reviewer" --jq '.id'
Write-Host "Repo $repo (owner id $ownerId, repo id $repoId). Prod reviewer: $Reviewer"

foreach ($e in @("dev", "test", "prod")) {
    $rg = "rg-ais-$rc-$wl-$e"
    $identityName = "id-ais-$rc-$wl-cicd-$e"

    # 1. the identity lives in the resource group it deploys to, so teardown of the group removes it
    $identity = az identity create --resource-group $rg --name $identityName --location $env:AZURE_LOCATION `
        --query "{clientId:clientId, principalId:principalId}" -o json | ConvertFrom-Json
    Write-Host "$e : identity $identityName  client id $($identity.clientId)"

    # 2. federated credential: GitHub jobs running in Environment <e> may sign in as this identity
    $subject = "repo:$owner@$ownerId/$name@${repoId}:environment:$e"
    az identity federated-credential create --name "github-$e" --identity-name $identityName --resource-group $rg `
        --issuer "https://token.actions.githubusercontent.com" --subject $subject --audiences "api://AzureADTokenExchange" `
        --query name -o tsv | Out-Null
    Write-Host "$e : federated credential -> $subject"

    # 3. Foundry Owner covers az deployment group create, the Foundry account, and the agents inside it.
    az role assignment create --assignee-object-id $identity.principalId --assignee-principal-type ServicePrincipal `
        --role "Foundry Owner" --scope "/subscriptions/$sub/resourceGroups/$rg" --query id -o tsv | Out-Null
    Write-Host "$e : Foundry Owner on $rg"

    # 4. GitHub Environment + variables. prevent_self_review is only accepted together with reviewers;
    #    it is false so a one-person team can approve its own prod run.
    $body = @{ wait_timer = 0; deployment_branch_policy = $null }
    if ($e -eq "prod") { $body.reviewers = @(@{ type = "User"; id = [int]$reviewerId }); $body.prevent_self_review = $false }
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value ($body | ConvertTo-Json -Depth 4 -Compress) -Encoding ascii
    gh api --method PUT "repos/$repo/environments/$e" --input $tmp --jq '.name' | Out-Null
    Remove-Item $tmp
    gh variable set AZURE_CLIENT_ID --env $e --body $identity.clientId --repo $repo
    gh variable set AZURE_TENANT_ID --env $e --body $tenant --repo $repo
    gh variable set AZURE_SUBSCRIPTION_ID --env $e --body $sub --repo $repo
    Write-Host "$e : GitHub Environment with 3 variables$(if ($e -eq 'prod') { " and required reviewer $Reviewer" })"
}
gh variable set REGION_CODE --body $rc --repo $repo
gh variable set WORKLOAD --body $wl --repo $repo
gh variable set AGENT_NAME --body $env:AGENT_NAME --repo $repo
Write-Host "Repository variables REGION_CODE, WORKLOAD, AGENT_NAME set."
Write-Host "Done. Role assignments can take up to 10 minutes to propagate before the first workflow run succeeds."
