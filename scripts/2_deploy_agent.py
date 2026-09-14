"""2_deploy_agent.py - create a new immutable version of the agent for one environment.

The agent IS its definition: a model deployment name plus agent/instructions.md. There is
no artifact to build. Each run creates the next version number; nothing is ever edited.

Usage:  python scripts/2_deploy_agent.py --env dev
"""
import argparse
import os
from pathlib import Path

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition, WebSearchTool
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")
parser = argparse.ArgumentParser()
parser.add_argument("--env", required=True, choices=["dev", "test", "prod"])
args = parser.parse_args()

rc, wl = os.environ["REGION_CODE"], os.environ["WORKLOAD"]
endpoint = f"https://msf-ais-{rc}-{wl}-{args.env}.services.ai.azure.com/api/projects/prj-ais-{rc}-{wl}-{args.env}"
agent = os.environ["AGENT_NAME"]  # same agent name in every environment; the project differs
project = AIProjectClient(endpoint=endpoint, credential=DefaultAzureCredential())

version = project.agents.create_version(
    agent_name=agent,
    definition=PromptAgentDefinition(
        model="chat-model",
        instructions=(ROOT / "agent" / "instructions.md").read_text(encoding="utf-8"),
        tools=[WebSearchTool()]
    ),
    metadata={"env": args.env, "git_sha": os.environ.get("GITHUB_SHA", "local")[:12]},
)
print(f"{version.name} version {version.version} created in {endpoint}")

if os.environ.get("GITHUB_OUTPUT"):  # hands the version number to the next workflow step
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
        handle.write(f"version={version.version}\n")
