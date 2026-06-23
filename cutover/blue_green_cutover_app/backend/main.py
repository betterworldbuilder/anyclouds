import asyncio
import math
import time
import uuid
from datetime import datetime, timezone
from statistics import mean
from typing import Dict, List, Optional

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel


app = FastAPI(title="Blue/Green Cutover Tester", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class ServerConfig(BaseModel):
    name: str
    base_url: str
    health_path: str = "/health"
    smoke_path: str = "/"
    expected_status: int = 200
    timeout_seconds: float = 5.0


class CutoverConfig(BaseModel):
    source: ServerConfig
    target: ServerConfig
    traffic_mode: str = "simulation"
    active_environment: str = "source"


class ProbeResult(BaseModel):
    environment: str
    name: str
    url: str
    ok: bool
    status_code: Optional[int] = None
    latency_ms: Optional[float] = None
    error: Optional[str] = None
    checked_at: str


class CutoverDecision(BaseModel):
    run_id: str
    allowed: bool
    source_health: ProbeResult
    target_health: ProbeResult
    smoke_test: ProbeResult
    recommendation: str
    created_at: str


class SwitchRequest(BaseModel):
    target_environment: str
    require_target_healthy: bool = True


class RollbackRequest(BaseModel):
    reason: str = "Manual rollback requested"


class PerformanceValidationRequest(BaseModel):
    sample_count: int = 12
    target_concurrent_users: int = 10
    active_sessions_tested: int = 10
    ospc_avg_response_ms: Optional[float] = None
    flex_avg_response_ms: Optional[float] = None
    ospc_p95_ms: Optional[float] = None
    flex_p95_ms: Optional[float] = None
    peak_concurrent_users_tested: Optional[int] = None
    api_error_rate_percent: Optional[float] = None
    db_avg_query_ms: Optional[float] = None
    report_generation_seconds: Optional[float] = None
    mobile_app_load_seconds: Optional[float] = None
    mobile_tap_response_ms: Optional[float] = None
    network_latency_ms: Optional[float] = None
    upload_mbps: Optional[float] = None
    download_mbps: Optional[float] = None
    mobile_lag_status: str = "Pass"


class PerformanceConfig(BaseModel):
    source_base_url: str
    target_base_url: str
    test_path: str = "/"
    health_path: str = "/health"
    concurrent_users: int = 10
    peak_concurrent_users: int = 25
    requests_per_user: int = 5
    timeout_seconds: float = 5.0
    max_avg_response_ms: float = 1000
    max_p95_ms: float = 2000
    max_error_rate_percent: float = 2.0
    review_avg_delta_ms: float = 250
    fail_avg_delta_ms: float = 750
    review_p95_delta_ms: float = 500
    fail_p95_delta_ms: float = 1500
    db_test_url: Optional[str] = None
    report_test_url: Optional[str] = None
    mobile_test_url: Optional[str] = None
    upload_test_url: Optional[str] = None
    download_test_url: Optional[str] = None


class EndpointPerfResult(BaseModel):
    environment: str
    base_url: str
    test_url: str
    total_requests: int
    successful_requests: int
    failed_requests: int
    error_rate_percent: float
    avg_response_ms: float
    p95_ms: float
    min_ms: float
    max_ms: float
    concurrent_users: int
    checked_at: str


class PerformanceValidationResult(BaseModel):
    ospc_avg_response_ms: float
    flex_avg_response_ms: float
    ospc_p95_ms: float
    flex_p95_ms: float
    target_concurrent_users: int
    peak_concurrent_users_tested: int
    active_sessions_tested: int
    api_error_rate_percent: float
    db_avg_query_ms: Optional[float] = None
    report_generation_seconds: Optional[float] = None
    mobile_app_load_seconds: Optional[float] = None
    mobile_tap_response_ms: Optional[float] = None
    network_latency_ms: Optional[float] = None
    upload_mbps: Optional[float] = None
    download_mbps: Optional[float] = None
    mobile_lag_status: str = "Review"
    avg_response_delta: float
    p95_delta: float
    performance_status: str
    source_result: EndpointPerfResult
    target_result: EndpointPerfResult
    recommendation: str
    created_at: str


STATE = {
    "config": None,
    "active_environment": "source",
    "audit": [],
    "performance_config": None,
    "latest_performance": None,
    "performance_audit": [],
}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def audit(event_type: str, details: Dict):
    event = {
        "id": str(uuid.uuid4()),
        "event_type": event_type,
        "details": details,
        "created_at": now_iso(),
    }
    STATE["audit"].insert(0, event)
    STATE["audit"] = STATE["audit"][:200]
    return event


def performance_audit_event(result: PerformanceValidationResult):
    STATE["latest_performance"] = result
    STATE["performance_audit"].insert(0, result.model_dump())
    STATE["performance_audit"] = STATE["performance_audit"][:100]
    audit("PERFORMANCE_VALIDATION_RUN", result.model_dump())


def join_url(base_url: str, path: str) -> str:
    return base_url.rstrip("/") + "/" + path.lstrip("/")


async def probe(environment: str, cfg: ServerConfig, path: Optional[str] = None) -> ProbeResult:
    target_path = path or cfg.health_path
    url = join_url(cfg.base_url, target_path)
    started = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=cfg.timeout_seconds, follow_redirects=True) as client:
            response = await client.get(url)
        latency = round((time.perf_counter() - started) * 1000, 2)
        ok = response.status_code == cfg.expected_status
        return ProbeResult(
            environment=environment,
            name=cfg.name,
            url=url,
            ok=ok,
            status_code=response.status_code,
            latency_ms=latency,
            checked_at=now_iso(),
        )
    except Exception as exc:
        latency = round((time.perf_counter() - started) * 1000, 2)
        return ProbeResult(
            environment=environment,
            name=cfg.name,
            url=url,
            ok=False,
            latency_ms=latency,
            error=str(exc),
            checked_at=now_iso(),
        )


def _percentile(values: List[float], percentile: float) -> Optional[float]:
    clean = sorted(v for v in values if v is not None)
    if not clean:
        return None
    if len(clean) == 1:
        return round(clean[0], 2)
    rank = (len(clean) - 1) * percentile
    low = int(rank)
    high = min(low + 1, len(clean) - 1)
    weight = rank - low
    return round(clean[low] * (1 - weight) + clean[high] * weight, 2)


def percentile(values: List[float], pct: float) -> float:
    if not values:
        return 0
    sorted_values = sorted(values)
    index = math.ceil((pct / 100) * len(sorted_values)) - 1
    index = max(0, min(index, len(sorted_values) - 1))
    return sorted_values[index]


async def timed_get(client: httpx.AsyncClient, url: str) -> Dict:
    started = time.perf_counter()
    try:
        response = await client.get(url)
        elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
        return {
            "ok": 200 <= response.status_code < 400,
            "status_code": response.status_code,
            "elapsed_ms": elapsed_ms,
            "error": None,
        }
    except Exception as exc:
        elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
        return {
            "ok": False,
            "status_code": None,
            "elapsed_ms": elapsed_ms,
            "error": str(exc),
        }


async def run_endpoint_perf(
    environment: str,
    base_url: str,
    test_path: str,
    concurrent_users: int,
    requests_per_user: int,
    timeout_seconds: float,
) -> EndpointPerfResult:
    safe_concurrent = max(1, min(int(concurrent_users or 1), 100))
    safe_requests_per_user = max(1, min(int(requests_per_user or 1), 50))
    test_url = base_url.rstrip("/") + "/" + test_path.lstrip("/")
    total_requests = safe_concurrent * safe_requests_per_user
    sem = asyncio.Semaphore(safe_concurrent)

    async def bounded_get(client: httpx.AsyncClient):
        async with sem:
            return await timed_get(client, test_url)

    async with httpx.AsyncClient(timeout=timeout_seconds, follow_redirects=True) as client:
        results = await asyncio.gather(*(bounded_get(client) for _ in range(total_requests)))

    latencies = [r["elapsed_ms"] for r in results]
    successful = [r for r in results if r["ok"]]
    failed = [r for r in results if not r["ok"]]
    return EndpointPerfResult(
        environment=environment,
        base_url=base_url,
        test_url=test_url,
        total_requests=total_requests,
        successful_requests=len(successful),
        failed_requests=len(failed),
        error_rate_percent=round((len(failed) / total_requests) * 100, 2) if total_requests else 0,
        avg_response_ms=round(mean(latencies), 2) if latencies else 0,
        p95_ms=round(percentile(latencies, 95), 2) if latencies else 0,
        min_ms=round(min(latencies), 2) if latencies else 0,
        max_ms=round(max(latencies), 2) if latencies else 0,
        concurrent_users=safe_concurrent,
        checked_at=now_iso(),
    )


async def optional_single_probe_ms(url: Optional[str], timeout_seconds: float) -> Optional[float]:
    if not url:
        return None
    async with httpx.AsyncClient(timeout=timeout_seconds, follow_redirects=True) as client:
        result = await timed_get(client, url)
    return result["elapsed_ms"] if result["ok"] else None


def evaluate_performance(
    config: PerformanceConfig,
    source_result: EndpointPerfResult,
    target_result: EndpointPerfResult,
    db_avg_query_ms: Optional[float] = None,
    report_generation_seconds: Optional[float] = None,
    mobile_app_load_seconds: Optional[float] = None,
    mobile_tap_response_ms: Optional[float] = None,
    network_latency_ms: Optional[float] = None,
) -> tuple[str, str, float, float, str]:
    avg_delta = round(target_result.avg_response_ms - source_result.avg_response_ms, 2)
    p95_delta = round(target_result.p95_ms - source_result.p95_ms, 2)
    error_rate = target_result.error_rate_percent
    status = "PASS"
    reasons: List[str] = []

    if config.concurrent_users > 100:
        reasons.append("Requested concurrency above 100 was capped by the safe built-in runner.")
    if target_result.avg_response_ms > config.max_avg_response_ms:
        status = "FAIL"
        reasons.append("Target average response time breaches max threshold.")
    if target_result.p95_ms > config.max_p95_ms:
        status = "FAIL"
        reasons.append("Target P95 response time breaches max threshold.")
    if error_rate > config.max_error_rate_percent:
        status = "FAIL"
        reasons.append("Target API error rate breaches max threshold.")
    if avg_delta >= config.fail_avg_delta_ms:
        status = "FAIL"
        reasons.append("Target average response is much slower than source.")
    elif avg_delta >= config.review_avg_delta_ms and status != "FAIL":
        status = "REVIEW"
        reasons.append("Target average response is slower than source.")
    if p95_delta >= config.fail_p95_delta_ms:
        status = "FAIL"
        reasons.append("Target P95 is much slower than source.")
    elif p95_delta >= config.review_p95_delta_ms and status != "FAIL":
        status = "REVIEW"
        reasons.append("Target P95 is slower than source.")

    mobile_lag_status = "Pass"
    if mobile_tap_response_ms is not None and mobile_tap_response_ms > 500:
        mobile_lag_status = "Review"
    if mobile_tap_response_ms is not None and mobile_tap_response_ms > 1000:
        mobile_lag_status = "Fail"
        status = "FAIL"
        reasons.append("Mobile tap response is too slow.")
    if not reasons:
        reasons.append("Target performance is acceptable for cutover.")
    return status, mobile_lag_status, avg_delta, p95_delta, " ".join(reasons)


async def sample_endpoint(environment: str, cfg: ServerConfig, count: int, concurrency: int) -> Dict:
    count = max(1, min(int(count or 1), 100))
    concurrency = max(1, min(int(concurrency or 1), 50))
    sem = asyncio.Semaphore(concurrency)
    path = cfg.smoke_path or cfg.health_path

    async def one_sample(idx: int) -> ProbeResult:
        async with sem:
            return await probe(environment, cfg, path)

    results = await asyncio.gather(*(one_sample(i) for i in range(count)))
    latencies = [r.latency_ms for r in results if r.ok and r.latency_ms is not None]
    errors = [r for r in results if not r.ok]
    avg_ms = round(sum(latencies) / len(latencies), 2) if latencies else None
    p95_ms = _percentile(latencies, 0.95)
    error_rate = round((len(errors) / len(results)) * 100, 2) if results else 100.0
    return {
        "environment": environment,
        "samples": [r.model_dump() for r in results],
        "sample_count": len(results),
        "ok_count": len(results) - len(errors),
        "error_count": len(errors),
        "avg_response_ms": avg_ms,
        "p95_ms": p95_ms,
        "error_rate_percent": error_rate,
    }


def _metric_float(value: Optional[float], fallback: Optional[float] = None) -> Optional[float]:
    if value is None:
        return fallback
    try:
        return round(float(value), 2)
    except Exception:
        return fallback


def _metric_int(value: Optional[int], fallback: int = 0) -> int:
    if value is None:
        return fallback
    try:
        return int(value)
    except Exception:
        return fallback


def _performance_status(metrics: Dict) -> Dict[str, object]:
    status = "Pass"
    reasons: List[str] = []
    api_error = float(metrics.get("api_error_rate_percent") or 0)
    avg_delta = metrics.get("avg_response_delta")
    p95_delta = metrics.get("p95_delta")
    mobile_lag = str(metrics.get("mobile_lag_status") or "Pass").lower()
    if api_error > 5:
        status = "Fail"
        reasons.append("API error rate is above 5%.")
    elif api_error > 1:
        status = "Review"
        reasons.append("API error rate is above 1%.")
    if avg_delta is not None and metrics.get("ospc_avg_response_ms"):
        source = float(metrics.get("ospc_avg_response_ms") or 0)
        if source > 0 and avg_delta > source * 0.30:
            status = "Fail"
            reasons.append("FLEX average response is more than 30% slower than OSPC.")
        elif source > 0 and avg_delta > source * 0.15 and status != "Fail":
            status = "Review"
            reasons.append("FLEX average response is more than 15% slower than OSPC.")
    if p95_delta is not None and metrics.get("ospc_p95_ms"):
        source = float(metrics.get("ospc_p95_ms") or 0)
        if source > 0 and p95_delta > source * 0.35:
            status = "Fail"
            reasons.append("FLEX P95 response is more than 35% slower than OSPC.")
        elif source > 0 and p95_delta > source * 0.20 and status != "Fail":
            status = "Review"
            reasons.append("FLEX P95 response is more than 20% slower than OSPC.")
    if mobile_lag not in {"pass", "ok", "none", ""}:
        if status != "Fail":
            status = "Review"
        reasons.append("Mobile lag status requires review.")
    if not reasons:
        reasons.append("Performance is within cutover thresholds.")
    return {"performance_status": status, "reasons": reasons}


def get_config() -> CutoverConfig:
    if STATE["config"] is None:
        raise HTTPException(status_code=400, detail="Cutover config not set. POST /config first.")
    return STATE["config"]


@app.get("/")
def root():
    return {
        "app": "Blue/Green Cutover Tester",
        "active_environment": STATE["active_environment"],
        "traffic_mode": (STATE["config"].traffic_mode if STATE["config"] else "simulation"),
        "docs": "/docs",
    }


@app.post("/config")
def set_config(config: CutoverConfig):
    STATE["config"] = config
    STATE["active_environment"] = config.active_environment
    audit("CONFIG_SET", config.model_dump())
    return {"ok": True, "config": config, "active_environment": STATE["active_environment"]}


@app.get("/config")
def read_config():
    return {"config": STATE["config"], "active_environment": STATE["active_environment"]}


@app.get("/health-check")
async def health_check():
    config = get_config()
    source, target = await asyncio.gather(
        probe("source", config.source),
        probe("target", config.target),
    )
    audit("HEALTH_CHECK", {"source": source.model_dump(), "target": target.model_dump()})
    return {"source": source, "target": target, "active_environment": STATE["active_environment"]}


@app.get("/smoke-test")
async def smoke_test():
    config = get_config()
    source_result, target_result = await asyncio.gather(
        probe("source", config.source, config.source.smoke_path),
        probe("target", config.target, config.target.smoke_path),
    )
    audit("SMOKE_TEST", {"source": source_result.model_dump(), "target": target_result.model_dump()})
    return {"source": source_result, "target": target_result}


@app.post("/pre-cutover-check", response_model=CutoverDecision)
async def pre_cutover_check():
    config = get_config()
    source_health, target_health = await asyncio.gather(
        probe("source", config.source),
        probe("target", config.target),
    )
    smoke = await probe("target", config.target, config.target.smoke_path)
    allowed = source_health.ok and target_health.ok and smoke.ok
    recommendation = (
        "CUTOVER_ALLOWED: source is reachable, target is healthy, and target smoke test passed."
        if allowed
        else "CUTOVER_BLOCKED: fix failed health/smoke checks before switching production traffic."
    )
    decision = CutoverDecision(
        run_id=str(uuid.uuid4()),
        allowed=allowed,
        source_health=source_health,
        target_health=target_health,
        smoke_test=smoke,
        recommendation=recommendation,
        created_at=now_iso(),
    )
    audit("PRE_CUTOVER_CHECK", decision.model_dump())
    return decision


@app.post("/performance/config")
def set_performance_config(config: PerformanceConfig):
    STATE["performance_config"] = config
    event = audit("PERFORMANCE_CONFIG_SET", config.model_dump())
    return {"ok": True, "config": config, "event": event}


@app.post("/performance/run", response_model=PerformanceValidationResult)
async def run_performance_validation():
    config = STATE.get("performance_config")
    if config is None:
        raise HTTPException(status_code=400, detail="Performance config not set. POST /performance/config first.")

    source_result, target_result = await asyncio.gather(
        run_endpoint_perf(
            "source",
            config.source_base_url,
            config.test_path,
            config.concurrent_users,
            config.requests_per_user,
            config.timeout_seconds,
        ),
        run_endpoint_perf(
            "target",
            config.target_base_url,
            config.test_path,
            config.concurrent_users,
            config.requests_per_user,
            config.timeout_seconds,
        ),
    )

    db_avg_query_ms = await optional_single_probe_ms(config.db_test_url, config.timeout_seconds)
    report_ms = await optional_single_probe_ms(config.report_test_url, config.timeout_seconds)
    mobile_load_ms = await optional_single_probe_ms(config.mobile_test_url, config.timeout_seconds)

    report_generation_seconds = round(report_ms / 1000, 2) if report_ms is not None else None
    mobile_app_load_seconds = round(mobile_load_ms / 1000, 2) if mobile_load_ms is not None else None
    mobile_tap_response_ms = mobile_load_ms
    network_latency_ms = target_result.min_ms

    performance_status, mobile_lag_status, avg_delta, p95_delta, recommendation = evaluate_performance(
        config,
        source_result,
        target_result,
        db_avg_query_ms=db_avg_query_ms,
        report_generation_seconds=report_generation_seconds,
        mobile_app_load_seconds=mobile_app_load_seconds,
        mobile_tap_response_ms=mobile_tap_response_ms,
        network_latency_ms=network_latency_ms,
    )

    result = PerformanceValidationResult(
        ospc_avg_response_ms=source_result.avg_response_ms,
        flex_avg_response_ms=target_result.avg_response_ms,
        ospc_p95_ms=source_result.p95_ms,
        flex_p95_ms=target_result.p95_ms,
        target_concurrent_users=min(config.concurrent_users, 100),
        peak_concurrent_users_tested=config.peak_concurrent_users,
        active_sessions_tested=min(config.concurrent_users, 100),
        api_error_rate_percent=target_result.error_rate_percent,
        db_avg_query_ms=db_avg_query_ms,
        report_generation_seconds=report_generation_seconds,
        mobile_app_load_seconds=mobile_app_load_seconds,
        mobile_tap_response_ms=mobile_tap_response_ms,
        network_latency_ms=network_latency_ms,
        upload_mbps=None,
        download_mbps=None,
        mobile_lag_status=mobile_lag_status,
        avg_response_delta=avg_delta,
        p95_delta=p95_delta,
        performance_status=performance_status,
        source_result=source_result,
        target_result=target_result,
        recommendation=recommendation,
        created_at=now_iso(),
    )
    performance_audit_event(result)
    return result


@app.get("/performance/latest")
def latest_performance():
    if STATE.get("latest_performance") is None:
        raise HTTPException(status_code=404, detail="No performance validation has been run yet.")
    return STATE["latest_performance"]


@app.get("/performance/audit")
def performance_audit():
    return STATE.get("performance_audit", [])


@app.post("/performance-validation")
async def performance_validation(req: PerformanceValidationRequest):
    config = get_config()
    concurrency = max(1, min(req.target_concurrent_users or 1, 50))
    sample_count = max(1, min(req.sample_count or concurrency, 100))
    source_sample, target_sample = await asyncio.gather(
        sample_endpoint("source", config.source, sample_count, concurrency),
        sample_endpoint("target", config.target, sample_count, concurrency),
    )
    ospc_avg = _metric_float(req.ospc_avg_response_ms, source_sample.get("avg_response_ms"))
    flex_avg = _metric_float(req.flex_avg_response_ms, target_sample.get("avg_response_ms"))
    ospc_p95 = _metric_float(req.ospc_p95_ms, source_sample.get("p95_ms"))
    flex_p95 = _metric_float(req.flex_p95_ms, target_sample.get("p95_ms"))
    combined_error = round(((source_sample.get("error_rate_percent") or 0) + (target_sample.get("error_rate_percent") or 0)) / 2, 2)
    metrics = {
        "ospc_avg_response_ms": ospc_avg,
        "flex_avg_response_ms": flex_avg,
        "ospc_p95_ms": ospc_p95,
        "flex_p95_ms": flex_p95,
        "target_concurrent_users": _metric_int(req.target_concurrent_users, concurrency),
        "peak_concurrent_users_tested": _metric_int(req.peak_concurrent_users_tested, concurrency),
        "active_sessions_tested": _metric_int(req.active_sessions_tested, concurrency),
        "api_error_rate_percent": _metric_float(req.api_error_rate_percent, combined_error),
        "db_avg_query_ms": _metric_float(req.db_avg_query_ms),
        "report_generation_seconds": _metric_float(req.report_generation_seconds),
        "mobile_app_load_seconds": _metric_float(req.mobile_app_load_seconds),
        "mobile_tap_response_ms": _metric_float(req.mobile_tap_response_ms),
        "network_latency_ms": _metric_float(req.network_latency_ms),
        "upload_mbps": _metric_float(req.upload_mbps),
        "download_mbps": _metric_float(req.download_mbps),
        "mobile_lag_status": req.mobile_lag_status or "Pass",
        "avg_response_delta": round((flex_avg - ospc_avg), 2) if flex_avg is not None and ospc_avg is not None else None,
        "p95_delta": round((flex_p95 - ospc_p95), 2) if flex_p95 is not None and ospc_p95 is not None else None,
    }
    metrics.update(_performance_status(metrics))
    payload = {
        "ok": metrics["performance_status"] != "Fail",
        "metrics": metrics,
        "source_sample": source_sample,
        "target_sample": target_sample,
        "created_at": now_iso(),
    }
    audit("PERFORMANCE_VALIDATION", payload)
    return payload


@app.post("/switch")
async def switch_traffic(req: SwitchRequest):
    config = get_config()
    if req.target_environment not in ["source", "target"]:
        raise HTTPException(status_code=400, detail="target_environment must be source or target")
    target_cfg = config.source if req.target_environment == "source" else config.target
    target_health = await probe(req.target_environment, target_cfg)
    if req.require_target_healthy and not target_health.ok:
        audit("SWITCH_BLOCKED", {"request": req.model_dump(), "health": target_health.model_dump()})
        raise HTTPException(
            status_code=409,
            detail={
                "message": "Switch blocked because target environment is unhealthy.",
                "health": target_health.model_dump(),
            },
        )
    previous = STATE["active_environment"]
    STATE["active_environment"] = req.target_environment
    event = audit(
        "TRAFFIC_SWITCHED",
        {
            "previous_environment": previous,
            "new_environment": req.target_environment,
            "traffic_mode": config.traffic_mode,
            "health": target_health.model_dump(),
        },
    )
    return {
        "ok": True,
        "previous_environment": previous,
        "active_environment": STATE["active_environment"],
        "event": event,
        "note": "Simulation mode. Connect a real switcher before treating traffic as moved.",
    }


@app.post("/rollback")
async def rollback(req: RollbackRequest):
    config = get_config()
    previous = STATE["active_environment"]
    STATE["active_environment"] = "source"
    source_health = await probe("source", config.source)
    event = audit(
        "ROLLBACK",
        {
            "previous_environment": previous,
            "active_environment": "source",
            "reason": req.reason,
            "source_health": source_health.model_dump(),
        },
    )
    return {"ok": True, "active_environment": STATE["active_environment"], "event": event}


@app.get("/audit")
def audit_log():
    return STATE["audit"]
