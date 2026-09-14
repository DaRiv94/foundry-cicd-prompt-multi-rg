# Prompt agent CI/CD, three resource groups (recommended topology)

This project promotes a Microsoft Foundry prompt agent from dev to test to prod when each environment is its own resource group with its own Foundry account and project. The agent is a Frankies Bakery customer service agent: one model deployment plus `agent/instructions.md`, no tools.

The agent has the same name in every environment. What differs is the project it lives in. Every promotion creates a new immutable version of the agent in the next project from the same instructions file. Prod is pinned to the version that passed the gate.

```
rg-ais-eus-pamulti-dev                   rg-ais-eus-pamulti-test                  rg-ais-eus-pamulti-prod
  msf-ais-eus-pamulti-dev                  msf-ais-eus-pamulti-test                 msf-ais-eus-pamulti-prod
    chat-model                               chat-model                               chat-model (capacity 20)
    prj-ais-eus-pamulti-dev                  prj-ais-eus-pamulti-test                 prj-ais-eus-pamulti-prod
      frankies-bakery-support                  frankies-bakery-support                  frankies-bakery-support
      endpoint serves latest                   evaluation gate runs here                endpoint PINNED
  id-ais-eus-pamulti-cicd-dev              id-ais-eus-pamulti-cicd-test             id-ais-eus-pamulti-cicd-prod
```

Zero secrets. Each GitHub Environment signs in to Azure with OpenID Connect as the managed identity that lives in its own resource group. The dev identity cannot touch prod. The Foundry accounts have local auth disabled, so there is no key to leak.

## How promotion works

| Stage | Trigger | What runs | Gate |
|---|---|---|---|
| dev | push to any branch except `main` | deploy infra into the dev group, create a new agent version, smoke test | none |
| test | push to `main` (job 2 of the Release run) | deploy infra into the test group, new version, smoke test, evaluation gate | 6-row evaluation, 80 percent must pass |
| prod | push to `main` (job 3 of the Release run) | wait for the reviewer, deploy infra into the prod group, new version, pin the endpoint, smoke test the pin | a person approves |

The Release run moves the same commit through dev, test, and prod. The prod job waits because the `prod` GitHub Environment has a required reviewer. The evaluation gate blocks prod because the prod job declares `needs: test`.

## Prerequisites

Azure

- A subscription where you can create resource groups and role assignments.
- Quota for `gpt-5-nano` GlobalStandard in East US: 10K tokens per minute for dev and test, 20K for prod, 40K in total.

Local machine

- Azure CLI 2.80 or later with Bicep (`az bicep upgrade`).
- GitHub CLI (`gh auth login` with the `repo` and `workflow` scopes).
- Python 3.12.
- PowerShell 7 or Bash. Every script has both.

GitHub

- A public repo. Required reviewers on Environments are free only on public repos.

## Files in this folder

- `agent/instructions.md` is the agent. Edit this file to change the agent, then promote it.
- `evals/bakery-eval-set.jsonl` holds six questions with the phrase each answer must contain.
- `infra/main.bicep` creates a Foundry account, a project, the `chat-model` deployment, and one role assignment for ONE environment. Nothing in it is environment specific.
- `infra/main.dev.bicepparam`, `main.test.bicepparam`, `main.prod.bicepparam` are the only per-environment files. Each sets `env`. Prod also raises `chatCapacity`.
- `scripts/0_prepare` creates the three resource groups and grants you Foundry Owner on each.
- `scripts/0b_pipeline_identity` creates one managed identity per group, its federated credential, the GitHub Environments, and the variables.
- `scripts/1_deploy_infra` runs the Bicep deployment for one environment. The pipeline runs this same file.
- `scripts/2_deploy_agent.py` creates a new immutable version of the agent in one environment's project.
- `scripts/3_smoke_test.py` asks the agent endpoint one question and fails on an empty answer.
- `scripts/4_evaluate.py` runs the evaluation gate against one version and exits 1 below 80 percent.
- `scripts/5_pin_version.py` routes 100 percent of the prod endpoint to one version. Rollback uses the same script.
- `scripts/99_teardown` deletes the three resource groups.
- `.github/workflows/deploy-stage.yml` is the one reusable stage. `dev.yml` and `release.yml` call it.
- `adding-capabilities.md` explains what changes when you add web search, file search, Azure AI Search, an MCP server, or code execution.

## Set up

Windows (PowerShell)

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
az login
```

Mac / Linux (Bash)

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
az login
```

Open `.env` and replace the two placeholders: your subscription id and, for later, your GitHub repo as `owner/name`. Every script refuses to run while a placeholder is still there.

## Run it locally first

Do the whole promotion by hand once. It is the same sequence the pipeline runs, so when the pipeline runs later you already know every step.

Windows (PowerShell)

```powershell
.\scripts\0_prepare.ps1

# dev
.\scripts\1_deploy_infra.ps1 -Env dev
python scripts\2_deploy_agent.py --env dev
python scripts\3_smoke_test.py --env dev

# test: the gate runs here
.\scripts\1_deploy_infra.ps1 -Env test
python scripts\2_deploy_agent.py --env test
python scripts\3_smoke_test.py --env test
python scripts\4_evaluate.py --env test --agent-version 1

# prod: pin, then prove the pin
.\scripts\1_deploy_infra.ps1 -Env prod
python scripts\2_deploy_agent.py --env prod
python scripts\5_pin_version.py --env prod --agent-version 1
python scripts\3_smoke_test.py --env prod
```

Mac / Linux (Bash)

```bash
./scripts/0_prepare.sh

# dev
./scripts/1_deploy_infra.sh dev
python scripts/2_deploy_agent.py --env dev
python scripts/3_smoke_test.py --env dev

# test: the gate runs here
./scripts/1_deploy_infra.sh test
python scripts/2_deploy_agent.py --env test
python scripts/3_smoke_test.py --env test
python scripts/4_evaluate.py --env test --agent-version 1

# prod: pin, then prove the pin
./scripts/1_deploy_infra.sh prod
python scripts/2_deploy_agent.py --env prod
python scripts/5_pin_version.py --env prod --agent-version 1
python scripts/3_smoke_test.py --env prod
```

What you see

- `1_deploy_infra` prints that environment's project endpoint. Each environment takes two to three minutes the first time and seconds after that.
- `2_deploy_agent` prints `frankies-bakery-support version 1 created in https://msf-ais-eus-pamulti-dev...`. Run it again and you get version 2. Versions are never edited. Version numbers count per project, so dev, test, and prod each start at 1.
- `4_evaluate` polls for about two minutes, prints one line per question, then `Pass rate 6/6 = 100% (minimum 80%)` and `GATE PASSED`. It also prints a link to the report in the Foundry portal.
- `5_pin_version` prints which version the prod endpoint now serves.

Where to look in the Foundry portal: you have three projects. Open each one, then Agents. Each project has one agent with its own version history and its own `git_sha` and `env` metadata. In the prod project the endpoint settings show the pinned version instead of "always use latest".

## Wire up GitHub

1. Create a public repo and push this folder to its `main` branch.
2. Put the repo name in `.env` as `GITHUB_REPO=owner/name`.
3. Run the bootstrap script. It needs `az login` and `gh auth login`.

Windows (PowerShell)

```powershell
.\scripts\0b_pipeline_identity.ps1
```

Mac / Linux (Bash)

```bash
./scripts/0b_pipeline_identity.sh
```

It creates one managed identity in each resource group with one federated credential each. The dev credential trusts only jobs that run inside the `dev` GitHub Environment, and the same for test and prod. So the prod identity, the only one with rights on the prod group, is only reachable from a job a reviewer has approved. Each identity gets Foundry Owner on its own group and nothing else. Foundry Owner covers `az deployment group create`, the Foundry account, and the agents inside it.

4. Wait about ten minutes for the role assignments to propagate, then push a change or start the Release workflow from the Actions tab.

Federated credential subjects: GitHub issues an immutable subject for repos created after July 2026, `repo:OWNER@OWNER-ID/REPO@REPO-ID:environment:NAME`. The script reads both ids with `gh api` and builds that subject. If the first login fails with `AADSTS70021`, the error shows the subject GitHub sent. Compare it with `az identity federated-credential list`.

## The promotion loop

This is the loop a developer runs every day.

1. Create a branch and edit `agent/instructions.md`. For example, change Saturday closing time from 6 PM to 5 PM.
2. Push the branch. The Dev workflow deploys a new version into the dev project and smoke tests it. Open the run in the Actions tab and read the answer in the smoke test step.
3. Open a pull request and merge it.
4. The Release workflow starts on `main`: the dev job runs again on the merge commit, then the test job creates a version in the test project and runs the evaluation gate, then the prod job waits.
5. Approve the prod job in the Actions tab. It creates the version in the prod project, pins the endpoint to it, and smoke tests the pinned endpoint. The smoke test output shows the new closing time.

Nothing reaches prod without a passing gate on the exact commit and a human approval. Note what "promotion" means here: the version in prod is not the version object from test. Agent versions belong to one project and cannot be moved between projects. What moves is the source, `agent/instructions.md` at one commit, and each project gets a fresh version built from it.

## Break the gate

See the gate do its job once.

1. On a branch, delete rule 3 from `agent/instructions.md` (the "I will connect you with a team member" sentence) and change the Sunday hours to "9 AM to 2 PM Sunday".
2. Merge it. The test job's evaluation step fails two of six rows, prints `Pass rate 4/6 = 67%`, exits 1, and the prod job never starts.
3. Restore both edits and merge. The gate passes and prod gets the fixed version.

The gate tolerates one miss on purpose. Six rows is small. With a real evaluation set you raise the row count and the threshold together.

## Rollback

Prod serves one pinned version. To go back, pin the previous one.

Windows (PowerShell)

```powershell
python scripts\5_pin_version.py --env prod --agent-version 1
```

Mac / Linux (Bash)

```bash
python scripts/5_pin_version.py --env prod --agent-version 1
```

A pin cannot be removed, only re-pointed. There is no way back to "always use latest" once an endpoint is pinned, which is fine: prod should never serve "whatever was created last".

## Where a bigger gate would go

The gate is one deterministic substring check per row, so it needs no judge model. To add an LLM-judged criterion such as task adherence, deploy a judge model in Bicep (`main.test.bicepparam` is where a test-only deployment belongs) and add a second entry to `testing_criteria` in `scripts/4_evaluate.py`. The pipeline does not change.

## Cost

Foundry accounts, projects, and agents cost nothing while idle, and three of them cost nothing three times. You pay for tokens when a smoke test or evaluation runs, and six evaluation rows on gpt-5-nano cost a fraction of a cent. What triples is quota: three accounts reserve three model deployments.

## Teardown

Windows (PowerShell)

```powershell
.\scripts\99_teardown.ps1
```

Mac / Linux (Bash)

```bash
./scripts/99_teardown.sh
```

The script lists the three resource groups, asks you to type DELETE, and deletes them. The managed identities and the role assignments live inside the groups, so nothing is left behind in Azure. The GitHub repo and its Environments stay and cost nothing.

## When to use this topology

Use three resource groups when the agent has real users. Each environment has its own account, quota, project, identity, and role assignments. A developer with rights on the dev group cannot see or change prod. Cost reports split per group. Prod capacity is prod's alone.

Do not use it for a throwaway prototype where the extra groups slow you down. Project `02-prompt-agent-single-rg` shows the same agent in one project with a fraction of the setup.

I recommend this topology for anything with real users because the isolation costs nothing extra while idle and the pipeline is the same three jobs either way. The only real difference is three parameter files and three identities instead of one.

## Adding capabilities

See `adding-capabilities.md` for what changes when you add web search, file search, RAG with Azure AI Search, an MCP server, or code execution.
