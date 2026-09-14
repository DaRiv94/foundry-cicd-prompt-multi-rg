# Adding capabilities: prompt agent, three resource groups

The baseline agent is one model deployment plus `agent/instructions.md`. `scripts/2_deploy_agent.py` builds `PromptAgentDefinition(model="chat-model", instructions=...)` with no tools, and dev, test, and prod are three Foundry projects in three resource groups. Each group has its own pipeline identity holding Foundry Owner on that group and nothing else.

Each section below adds ONE capability to that baseline, alone. The last section covers what changes only when all five are added together.

| Capability | New Azure resource | New project connection | Change in `2_deploy_agent.py` | Copies in this topology | Evaluation rows | Idle cost |
|---|---|---|---|---|---|---|
| Web search | none | none | `tools=[WebSearchTool()]` | none, one line serves all three projects | answers change daily, so check a stable phrase or add a judge | none |
| File search | none, the vector store is a data-plane object | none | upload step, then `FileSearchTool(vector_store_ids=[id])` | three vector stores, one per project | substring checks keep working | about zero |
| RAG with Azure AI Search | one search service per group plus four role assignments each | one `search-conn` per project | `AzureAISearchTool(...)` plus an index step | three services, three connections, three indexes | substring checks keep working | about $75 per month, three times |
| MCP server | none | one `bakery-orders-conn` per project when the server needs a key | `MCPTool(...)` | three connections, three secrets | substring checks work against your own seeded server | none |
| Code execution | none | none | `tools=[CodeInterpreterTool()]` | none | deterministic math rows | per session while it runs |

Every one of these creates a new agent version when you promote it, because a tool change is a definition change. Prod keeps serving the old pinned version until the prod job pins the new one. That is the same loop as an instructions edit.

## 1. Web search

Bicep: no change.

Definition: import `WebSearchTool` from `azure.ai.projects.models` and add one argument.

```python
definition=PromptAgentDefinition(
    model="chat-model",
    instructions=...,
    tools=[WebSearchTool()],
)
```

Restrict it to your own sites with `WebSearchTool(filters=WebSearchToolFilters(allowed_domains=["frankiesbakery.example"]))`, or the model answers bakery questions from the public web.

Scripts and pipeline: no new step, variable, or output. The instructions must say when to search ("for anything about today's weather or local events, search the web"), or the model answers from memory and never calls the tool.

Evaluation gate: a web answer is different every day, so a substring check on the answer text is fragile. Two choices. Check a phrase the instructions force regardless of the search result, for example the escalation sentence. Or add an LLM-judged criterion, which means a judge model deployment in Bicep and a second entry in `testing_criteria`. This capability is the one that pulls a judge model into the project, and `main.test.bicepparam` is where a test-only judge deployment belongs.

Smoke test: ask "Is Frankies Bakery open today?" and check for a `web_search_call` item in `response.output` instead of checking the text.

This topology and agent type: nothing per environment. The only per-environment artifact is the agent version itself, which the pipeline already creates three times. The tool needs no id or connection, so it is identical in every project.

Cost: per search call, nothing idle.

What does not change: Bicep, the parameter files, the identities and their roles, connections, the pin, the workflows.

## 2. File search

Bicep: no change. A vector store lives inside a project's data plane, so ARM never sees it.

New file: `agent/policies.md` with the refund policy, allergen statement, and catering lead times.

New step, before the agent version is created:

```python
openai = project.get_openai_client()
store = openai.vector_stores.create(name="bakery-policies")
with open(ROOT / "agent" / "policies.md", "rb") as handle:
    openai.vector_stores.files.upload_and_poll(vector_store_id=store.id, file=handle)
```

Definition: `tools=[FileSearchTool(vector_store_ids=[store.id])]`.

Scripts and pipeline: put the upload in `2_deploy_agent.py` before `create_version`, so one script still does one environment. No new workflow step, variable, or output. The store id is written into the version, which means rolling back the agent also rolls back to the store that version references.

Evaluation gate: add rows whose expected phrase comes from `policies.md`, for example "What is the refund policy on custom cakes?" expecting "14 days". Substring checks keep working because the data is yours.

Smoke test: ask a question only the policy file answers.

This topology and agent type: vector stores are project scoped, and the projects are separate. The upload runs once per stage, so dev, test, and prod each get their own store with their own id, created from the same `policies.md` at the same commit. Ids never cross environments. A store id pasted from dev into prod fails with a 404 because prod is a different project. The prod store is created after the reviewer approves, so what the reviewer approves is the source, not a data object.

Cost: storage after the first free gigabyte, so a few kilobytes cost nothing.

What does not change: Bicep, connections, the identities, the workflows.

## 3. RAG with Azure AI Search

Bicep: add a search service, a project connection, and four role assignments to `infra/main.bicep`. Because the template is deployed once per group, every environment gets its own copy.

```bicep
resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: 'srch-ais-${regionCode}-${workload}-${env}'
  location: location
  sku: { name: 'basic' }
  identity: { type: 'SystemAssigned' }
  properties: { replicaCount: 1, partitionCount: 1, disableLocalAuth: true, semanticSearch: 'free' }
}
resource searchConn 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: project
  name: 'search-conn'
  properties: { category: 'CognitiveSearch', authType: 'AAD', target: 'https://${search.name}.search.windows.net', isSharedToAll: true, metadata: { ApiType: 'Azure', ResourceId: search.id } }
}
```

Role assignments on the search service: the project identity needs BOTH Search Index Data Reader and Search Service Contributor, or the agent fails at query time with an error that never names the missing role. The pipeline identity needs Search Service Contributor and Search Index Data Contributor to create the index and upload documents.

New file: `agent/faq.jsonl` with an id, a title, and a content field per row.

New step, before the agent version: create the index and upload the rows with the `azure-search-documents` package. The index name is the same in every project, `bakery-faq`, because each project has its own search service.

Definition:

```python
conn_id = project.connections.get("search-conn").id
tools=[AzureAISearchTool(azure_ai_search=AzureAISearchToolResource(indexes=[
    AISearchIndexResource(project_connection_id=conn_id, index_name="bakery-faq", query_type=AzureAISearchQueryType.SIMPLE)
]))]
```

Scripts and pipeline: `requirements.txt` gains `azure-search-documents`. The identity is the biggest ripple in this project. Creating a search service needs Contributor on the resource group, and the role assignments Bicep writes need Role Based Access Control Administrator, because Foundry Owner may only assign Foundry User. So `0b_pipeline_identity` grows from one role to three, and it does so three times, once per identity. Role propagation takes one to five minutes, so the first smoke test after a fresh deployment may need a retry.

Verify on the first run: in an earlier live run the classic `AzureAISearchTool` rejected gpt-5 family models. If that happens, point `chatModelName` at a 4o family model, or use a Foundry IQ knowledge base on the same search service and attach it as `MCPTool(server_url=<knowledge base mcp url>, allowed_tools=["knowledge_base_retrieve"], project_connection_id=...)`, which works with every Responses model.

Evaluation gate: rows whose expected phrase comes from `faq.jsonl`. Substring checks keep working.

Smoke test: ask a question only the index answers and check for a `url_citation` annotation.

This topology and agent type: three search services, three connections, three indexes with the same name. Nothing keeps the three indexes identical except running the index step in every stage from the same `faq.jsonl`, which is the point of a pipeline. Bicep outputs the connection name per environment and the deploy script reads it, so no new GitHub variable is needed.

Cost: Basic tier idles at about $75 per month per service. This topology pays it three times, about $225 per month for a learning project, which is the loudest difference between the two topologies.

What does not change: agent name, `chat-model`, the workflows, the pin, the GitHub variables.

## 4. MCP server

Bicep: nothing for a public server. For a server that needs a key, one project connection per environment.

```bicep
param mcpServerUrl string
@secure()
param mcpServerKey string
resource ordersConn 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: project
  name: 'bakery-orders-conn'
  properties: { category: 'CustomKeys', authType: 'CustomKeys', target: mcpServerUrl, isSharedToAll: true, credentials: { keys: { 'x-functions-key': mcpServerKey } } }
}
```

`mcpServerUrl` goes into each parameter file, so dev, test, and prod can point at three server instances or at one.

Definition:

```python
tools=[MCPTool(
    server_label="bakery-orders",
    server_url=os.environ["MCP_SERVER_URL"],
    require_approval="never",
    allowed_tools=["get_order_status", "list_locations"],
    project_connection_id="bakery-orders-conn",
)]
```

Scripts and pipeline: `deploy-stage.yml` passes `--parameters mcpServerKey="${{ secrets.MCP_SERVER_KEY }}"` to the infra script. This is the first GitHub secret in the project, one per Environment. The Azure login stays keyless. The server's key is a downstream secret that lives on the connection and never in agent code.

Evaluation gate: `require_approval="never"` is forced by the gate, not a style choice. With `"always"` the response returns an `mcp_approval_request` item that the evaluation run cannot answer, and a one-shot smoke test hangs at the same point. Rows against your own seeded server ("What is the status of order 10231?" expecting "shipped") keep substring checks valid. A live third-party server makes rows nondeterministic.

Smoke test: check for an `mcp_call` item and no `mcp_approval_request` item.

This topology and agent type: three connections, three URLs in three parameter files, three secrets in three GitHub Environments. Rotating the key is a staged rollout: rotate dev, watch, rotate test, watch, rotate prod. The single project topology cannot stage a key rotation.

Cost: nothing in this project. The MCP server bills on its own.

What does not change: the model, the identities, the workflows, the pin.

## 5. Code execution

Bicep: no change.

Definition:

```python
from azure.ai.projects.models import CodeInterpreterTool
tools=[CodeInterpreterTool()]
```

To give the sandbox a file, upload it first with `openai.files.create(purpose="assistants", file=...)` and pass `CodeInterpreterTool(container=AutoCodeInterpreterToolParam(file_ids=[file.id]))`. File ids are project scoped, so the upload runs once per stage like the vector store.

Scripts and pipeline: no new step, variable, or output.

Evaluation gate: math rows are deterministic. "What is 17 percent of 84.50?" expecting "14.37" works with the substring check.

Smoke test: ask a calculation and check for a `code_interpreter_call` item.

This topology and agent type: nothing per environment. The sandbox is Microsoft managed. It runs on Azure Container Apps dynamic sessions, Hyper-V isolated, with no outbound network, in the same region as the project. A session lives for up to one hour with a thirty minute idle timeout, and two conversations calling it at the same time get two sessions.

Cost: a per-session charge on top of tokens while a session is active.

What does not change: Bicep, connections, the identities, the workflows, the pin.

## 6. All five together

Only the interactions are listed here.

- One `tools=[...]` list of five. `tool_choice` stays automatic, so the instructions must route: policies to file search, catalog and hours to the index, orders to the MCP server, anything current to the web, arithmetic to the code interpreter. Give web search `allowed_domains` or it competes with the index.
- Order of creation inside one stage: infra (search service, connections, roles), index documents, vector store, agent version, smoke test, evaluation gate (test), pin (prod). A failure before `create_version` leaves data updated but no new version, which is safe because versions are atomic.
- Role assignments accumulate only from Azure AI Search. Each of the three identities grows once, for that capability, and nothing else needs the extra roles.
- The evaluation set grows to about six rows plus two per tool. Web search is the one tool that pulls a judge model into Bicep, and once the judge exists in the test parameter file every row can use it. A single 80 percent threshold across all rows can pass while every web row fails, which argues for one threshold per criterion.
- The smoke test becomes five prompts, one per tool.
- File search and the code interpreter both take file ids, and file ids are project scoped, so one upload step per stage can feed both.
- Costs add up: three search services dominate. Nothing interacts.

Nothing else changes: the parameter file shape, the three identities, the GitHub Environments, the pin and rollback, one immutable version per deploy.
