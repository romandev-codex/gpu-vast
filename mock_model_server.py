import asyncio
import json
import os
from datetime import datetime
from pathlib import Path
from typing import Any, Dict

from aiohttp import web


MODEL_LOG_FILE = Path(os.getenv("MODEL_LOG_FILE", "./mock-model.log"))
MODEL_PORT = int(os.getenv("MODEL_SERVER_PORT", "18000"))


def append_log(line: str) -> None:
    MODEL_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with MODEL_LOG_FILE.open("a", encoding="utf-8") as fh:
        fh.write(f"{line}\n")


async def on_startup(_app: web.Application) -> None:
    append_log(f"INFO: mock server boot at {datetime.utcnow().isoformat()}Z")
    append_log("Application startup complete.")


async def completions(request: web.Request) -> web.Response:
    payload: Dict[str, Any] = await request.json()
    prompt = payload.get("prompt", "")
    max_tokens = int(payload.get("max_tokens", 16))

    text = f"[mock completion] prompt_len={len(prompt)} max_tokens={max_tokens}"
    body = {
        "id": "cmpl-mock-123",
        "object": "text_completion",
        "created": int(datetime.utcnow().timestamp()),
        "model": payload.get("model", "mock-model"),
        "choices": [
            {
                "index": 0,
                "text": text,
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": max(1, len(prompt) // 4),
            "completion_tokens": max_tokens,
            "total_tokens": max(1, len(prompt) // 4) + max_tokens,
        },
    }
    return web.json_response(body)


async def chat_completions(request: web.Request) -> web.Response:
    payload: Dict[str, Any] = await request.json()
    messages = payload.get("messages", [])
    joined = " | ".join(m.get("content", "") for m in messages if isinstance(m, dict))

    body = {
        "id": "chatcmpl-mock-123",
        "object": "chat.completion",
        "created": int(datetime.utcnow().timestamp()),
        "model": payload.get("model", "mock-model"),
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": f"[mock chat completion] {joined}"[:500],
                },
                "finish_reason": "stop",
            }
        ],
    }
    return web.Response(
        text=json.dumps(body),
        status=200,
        content_type="application/json",
    )


async def health(_request: web.Request) -> web.Response:
    return web.json_response({"status": "ok"})


def create_app() -> web.Application:
    app = web.Application()
    app.router.add_post("/v1/completions", completions)
    app.router.add_post("/v1/chat/completions", chat_completions)
    app.router.add_get("/health", health)
    app.on_startup.append(on_startup)
    return app


if __name__ == "__main__":
    app = create_app()
    web.run_app(app, host="127.0.0.1", port=MODEL_PORT)
