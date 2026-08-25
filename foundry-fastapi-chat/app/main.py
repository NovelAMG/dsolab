import os
from pathlib import Path
from typing import Literal

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .foundry_client import ConfigError, chat_completion

load_dotenv()

ROOT = Path(__file__).resolve().parents[1]
STATIC_DIR = ROOT / "static"

app = FastAPI(title=os.getenv("APP_TITLE", "Foundry Chat Console"))
app.mount("/assets", StaticFiles(directory=STATIC_DIR), name="assets")


class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str = Field(min_length=1, max_length=8000)


class ChatRequest(BaseModel):
    messages: list[ChatMessage] = Field(min_length=1, max_length=20)


class ChatResponse(BaseModel):
    reply: str


@app.get("/")
def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/health")
def health() -> dict[str, bool | str]:
    return {
        "ok": True,
        "endpoint_configured": bool(os.getenv("AZURE_OPENAI_ENDPOINT")),
        "deployment_configured": bool(os.getenv("AZURE_OPENAI_DEPLOYMENT")),
        "auth_mode": "api_key" if os.getenv("AZURE_OPENAI_API_KEY") else "entra",
    }


@app.post("/api/chat", response_model=ChatResponse)
def chat(request: ChatRequest) -> ChatResponse:
    try:
        messages = [message.model_dump() for message in request.messages]
        reply = chat_completion(messages)
    except ConfigError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Model call failed: {exc}") from exc

    return ChatResponse(reply=reply)
