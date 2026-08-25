import os
from typing import Iterable

from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import AzureOpenAI


class ConfigError(RuntimeError):
    pass


def _required_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise ConfigError(f"Missing required environment variable: {name}")
    return value


def _client() -> tuple[AzureOpenAI, str]:
    endpoint = _required_env("AZURE_OPENAI_ENDPOINT")
    deployment = _required_env("AZURE_OPENAI_DEPLOYMENT")
    api_version = os.getenv("AZURE_OPENAI_API_VERSION", "2024-10-21").strip()
    api_key = os.getenv("AZURE_OPENAI_API_KEY", "").strip()

    if api_key:
        return (
            AzureOpenAI(
                azure_endpoint=endpoint,
                api_key=api_key,
                api_version=api_version,
            ),
            deployment,
        )

    token_provider = get_bearer_token_provider(
        DefaultAzureCredential(),
        "https://cognitiveservices.azure.com/.default",
    )
    return (
        AzureOpenAI(
            azure_endpoint=endpoint,
            azure_ad_token_provider=token_provider,
            api_version=api_version,
        ),
        deployment,
    )


def chat_completion(messages: Iterable[dict[str, str]]) -> str:
    client, deployment = _client()
    response = client.chat.completions.create(
        model=deployment,
        messages=list(messages),
        temperature=0.3,
        max_tokens=700,
    )
    message = response.choices[0].message.content
    return message or ""
