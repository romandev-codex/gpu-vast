import os
from typing import Any, Dict

from aiohttp import ClientResponse, web
from vastai import BenchmarkConfig, HandlerConfig, LogActionConfig, Worker, WorkerConfig


MODEL_SERVER_URL = os.getenv("MODEL_SERVER_URL", "http://127.0.0.1")
MODEL_SERVER_PORT = int(os.getenv("MODEL_SERVER_PORT", "18000"))
MODEL_LOG_FILE = os.getenv("MODEL_LOG_FILE", "./mock-model.log")
MODEL_HEALTHCHECK_ENDPOINT = os.getenv("MODEL_HEALTHCHECK_ENDPOINT", "/health")


def completions_benchmark_generator() -> Dict[str, Any]:
    return {
        "model": os.getenv("MODEL_NAME", "mock-model"),
        "prompt": "Hello from benchmark",
        "max_tokens": 64,
        "temperature": 0.7,
    }


def workload_by_max_tokens(payload: Dict[str, Any]) -> float:
    return float(payload.get("max_tokens", 0))


def completions_request_parser(json_msg: Dict[str, Any]) -> Dict[str, Any]:
    if "prompt" not in json_msg:
        raise ValueError("prompt is required")

    parsed = dict(json_msg)
    parsed.setdefault("model", os.getenv("MODEL_NAME", "mock-model"))
    parsed.setdefault("max_tokens", 128)
    return parsed


async def pass_through_response(
    _client_request: web.Request,
    model_response: ClientResponse,
) -> web.Response:
    body = await model_response.read()
    return web.Response(
        body=body,
        status=model_response.status,
        content_type=model_response.content_type,
        headers={"X-Worker": "mock-pyworker"},
    )


worker_config = WorkerConfig(
    model_server_url=MODEL_SERVER_URL,
    model_server_port=MODEL_SERVER_PORT,
    model_log_file=MODEL_LOG_FILE,
    model_healthcheck_url=MODEL_HEALTHCHECK_ENDPOINT,
    handlers=[
        HandlerConfig(
            route="/v1/completions",
            allow_parallel_requests=True,
            max_queue_time=60.0,
            request_parser=completions_request_parser,
            response_generator=pass_through_response,
            workload_calculator=workload_by_max_tokens,
            benchmark_config=BenchmarkConfig(
                generator=completions_benchmark_generator,
                runs=4,
                concurrency=4,
            ),
        ),
        HandlerConfig(
            route="/v1/chat/completions",
            allow_parallel_requests=True,
            max_queue_time=60.0,
            workload_calculator=workload_by_max_tokens,
        ),
    ],
    log_action_config=LogActionConfig(
        on_load=["Application startup complete."],
        on_error=[
            "Traceback (most recent call last):",
            "RuntimeError:",
            "ERROR:",
        ],
        on_info=["INFO:", "Downloaded"],
    ),
)


if __name__ == "__main__":
    Worker(worker_config).run()
