"""Static discovery for an imported AI project.

Reads files. Never executes them: no notebook run, no dependency resolution, no
image build, no repository script. Every conclusion is drawn from file names,
manifests and source text, and each detection carries the evidence path that
produced it so a reviewer can check the claim.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Dict, List, Set

from .models import make_component

MAX_FILES_SCANNED = 6000
MAX_READ_BYTES = 512 * 1024  # per file; enough for manifests and source

SKIP_DIRS = {
    ".git", "node_modules", "__pycache__", ".venv", "venv", "env", ".tox",
    "dist", "build", ".next", ".cache", "site-packages", ".mypy_cache",
    ".pytest_cache", ".idea", ".vscode", "target",
}

# name -> (category, [import/marker tokens])
SIGNATURES: Dict[str, Dict[str, List[str]]] = {
    "app_framework": {
        "FastAPI": ["fastapi"],
        "Flask": ["flask"],
        "Django": ["django"],
        "Streamlit": ["streamlit"],
        "Gradio": ["gradio"],
        "Express": ["express"],
        "Spring": ["springframework"],
        "Go net/http": ["net/http"],
    },
    "ai_framework": {
        "LangChain": ["langchain"],
        "LlamaIndex": ["llama_index", "llamaindex"],
        "Semantic Kernel": ["semantic_kernel"],
        "CrewAI": ["crewai"],
        "AutoGen": ["autogen"],
        "Haystack": ["haystack"],
    },
    "model_runtime": {
        "Ollama": ["ollama"],
        "vLLM": ["vllm"],
        "HF Transformers": ["transformers"],
        "TGI": ["text_generation", "text-generation-inference"],
        "OpenAI-compatible API": ["openai"],
        "Anthropic API": ["anthropic"],
        "PyTorch": ["torch"],
        "TensorFlow": ["tensorflow"],
        "ONNX Runtime": ["onnxruntime"],
        "Triton": ["tritonclient"],
    },
    "vector_store": {
        "ChromaDB": ["chromadb"],
        "pgvector": ["pgvector"],
        "Milvus": ["pymilvus"],
        "Weaviate": ["weaviate"],
        "OpenSearch": ["opensearchpy", "opensearch-py"],
        "Pinecone": ["pinecone"],
        "FAISS": ["faiss"],
        "Qdrant": ["qdrant"],
    },
    "ml_framework": {
        "scikit-learn": ["sklearn", "scikit-learn"],
        "LightGBM": ["lightgbm"],
        "XGBoost": ["xgboost"],
        "SHAP": ["shap"],
    },
    "database": {
        "PostgreSQL": ["psycopg", "postgresql"],
        "MySQL": ["pymysql", "mysqlclient"],
        "MongoDB": ["pymongo"],
        "Redis": ["redis"],
        "SQLAlchemy": ["sqlalchemy"],
    },
}

DEPLOYMENT_ASSETS = {
    "Dockerfile": ["dockerfile"],
    "Docker Compose": ["docker-compose.yml", "docker-compose.yaml", "compose.yaml"],
    "Kubernetes": [".yaml", ".yml"],  # confirmed by content, below
    "Helm": ["chart.yaml"],
    "Terraform": [".tf"],
    "Ansible": ["playbook.yml", "ansible.cfg"],
    "GitHub Actions": [".github/workflows"],
    "Flux": ["kustomization.yaml"],
}

DEP_MANIFESTS = {
    "requirements.txt", "pyproject.toml", "poetry.lock", "pipfile", "pipfile.lock",
    "package.json", "package-lock.json", "yarn.lock", "go.mod", "pom.xml", "build.gradle",
}

# Secret detection. These match shapes, not values; a hit records the file and
# the pattern name only — never the matched text.
SECRET_PATTERNS = [
    ("AWS access key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("GitHub token", re.compile(r"gh[pousr]_[A-Za-z0-9]{16,}")),
    ("GitHub PAT", re.compile(r"github_pat_[A-Za-z0-9_]{20,}")),
    ("OpenAI key", re.compile(r"sk-[A-Za-z0-9]{20,}")),
    ("Anthropic key", re.compile(r"sk-ant-[A-Za-z0-9\-_]{20,}")),
    ("Slack token", re.compile(r"xox[baprs]-[A-Za-z0-9\-]{10,}")),
    ("Private key block", re.compile(r"-----BEGIN (RSA|EC|OPENSSH|PGP|DSA)? ?PRIVATE KEY-----")),
    ("Generic assigned secret", re.compile(
        r"(?i)\b(password|passwd|secret|api[_-]?key|token)\b\s*[:=]\s*['\"][^'\"\s]{8,}['\"]")),
]

URL_RE = re.compile(r"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]{4,}")
ROUTE_RE = re.compile(r"@(?:app|router)\.(get|post|put|patch|delete)\(\s*['\"]([^'\"]+)['\"]")
FLASK_ROUTE_RE = re.compile(r"@(?:app|bp|blueprint)\.route\(\s*['\"]([^'\"]+)['\"]")

# Hosts that are always internal/local and are noise in an egress inventory.
_LOCAL_HOSTS = ("localhost", "127.0.0.1", "0.0.0.0", "::1")


def _iter_files(root: Path) -> List[Path]:
    out: List[Path] = []
    for path in root.rglob("*"):
        if len(out) >= MAX_FILES_SCANNED:
            break
        if path.is_dir():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        out.append(path)
    return out


def _read(path: Path) -> str:
    try:
        if path.stat().st_size > MAX_READ_BYTES:
            with path.open("r", encoding="utf-8", errors="replace") as fh:
                return fh.read(MAX_READ_BYTES)
        return path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return ""


def _notebook_text(raw: str) -> str:
    """Concatenate a notebook's source cells; ignore outputs.

    Outputs routinely contain the results of a run against production data, so
    scanning them would produce findings about data the project does not ship.
    """
    try:
        nb = json.loads(raw)
    except Exception:
        return raw
    if not isinstance(nb, dict):
        return raw
    chunks: List[str] = []
    for cell in nb.get("cells") or []:
        if not isinstance(cell, dict):
            continue
        src = cell.get("source")
        if isinstance(src, list):
            chunks.append("".join(str(s) for s in src))
        elif isinstance(src, str):
            chunks.append(src)
    return "\n".join(chunks)


def scan_project(root_path: str) -> Dict[str, Any]:
    """Scan an imported project tree and return an evidence-bearing inventory."""
    root = Path(root_path)
    result: Dict[str, Any] = {
        "scanned": False,
        "file_count": 0,
        "truncated": False,
        "languages": {},
        "detected": {k: [] for k in SIGNATURES},
        "deployment_assets": [],
        "dependency_manifests": [],
        "notebooks": [],
        "api_routes": [],
        "external_endpoints": [],
        "secret_findings": [],
        "licenses": [],
        "has_tests": False,
        "has_healthcheck": False,
        "has_openapi": False,
        "evidence": {},
        "components": [],
    }
    if not root_path or not root.is_dir():
        # Brownfield FLEX systems have no tree. Say so rather than report an
        # empty scan as a clean one.
        result["note"] = "no source tree to scan (declared source only)"
        return result

    files = _iter_files(root)
    result["file_count"] = len(files)
    result["truncated"] = len(files) >= MAX_FILES_SCANNED
    result["scanned"] = True

    found: Dict[str, Set[str]] = {k: set() for k in SIGNATURES}
    evidence: Dict[str, str] = {}
    assets: Set[str] = set()
    endpoints: Set[str] = set()
    langs: Dict[str, int] = {}

    ext_lang = {
        ".py": "Python", ".js": "JavaScript", ".ts": "TypeScript", ".tsx": "TypeScript",
        ".java": "Java", ".go": "Go", ".rb": "Ruby", ".rs": "Rust", ".cs": "C#",
        ".ipynb": "Notebook", ".sh": "Shell", ".sql": "SQL",
    }

    for path in files:
        rel = str(path.relative_to(root))
        low = path.name.lower()
        ext = path.suffix.lower()

        if ext in ext_lang:
            langs[ext_lang[ext]] = langs.get(ext_lang[ext], 0) + 1

        if low in DEP_MANIFESTS:
            result["dependency_manifests"].append(rel)
        if low == "dockerfile" or low.endswith(".dockerfile"):
            assets.add("Dockerfile")
        if low in ("docker-compose.yml", "docker-compose.yaml", "compose.yaml"):
            assets.add("Docker Compose")
        if low == "chart.yaml":
            assets.add("Helm")
        if ext == ".tf":
            assets.add("Terraform")
        if ".github/workflows" in rel.replace("\\", "/"):
            assets.add("GitHub Actions")
        if low in ("openapi.yaml", "openapi.json", "swagger.yaml", "swagger.json"):
            result["has_openapi"] = True
        if low.startswith("license"):
            result["licenses"].append(rel)
        if "test" in rel.lower() and ext in (".py", ".js", ".ts", ".go", ".java"):
            result["has_tests"] = True
        if ext == ".ipynb":
            result["notebooks"].append(rel)

        # Only text-ish files are opened.
        if ext not in {
            ".py", ".js", ".ts", ".tsx", ".jsx", ".java", ".go", ".rb", ".rs", ".cs",
            ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf", ".env",
            ".txt", ".md", ".sh", ".bash", ".sql", ".ipynb", ".lock", ".tf", ".xml",
        } and low not in DEP_MANIFESTS and low != "dockerfile":
            continue

        raw = _read(path)
        if not raw:
            continue
        text = _notebook_text(raw) if ext == ".ipynb" else raw
        lowered = text.lower()

        # Kubernetes manifests are YAML with a specific shape.
        if ext in (".yaml", ".yml") and "apiversion:" in lowered and "kind:" in lowered:
            assets.add("Kubernetes")

        for category, entries in SIGNATURES.items():
            for label, tokens in entries.items():
                if label in found[category]:
                    continue
                for token in tokens:
                    if token in lowered:
                        found[category].add(label)
                        evidence[f"{category}:{label}"] = rel
                        break

        for pattern_name, rx in SECRET_PATTERNS:
            if rx.search(text):
                # Record that a secret shape exists and where. Never the value.
                result["secret_findings"].append({"file": rel, "pattern": pattern_name})

        for m in ROUTE_RE.finditer(text):
            result["api_routes"].append({"method": m.group(1).upper(), "path": m.group(2), "file": rel})
        for m in FLASK_ROUTE_RE.finditer(text):
            result["api_routes"].append({"method": "ANY", "path": m.group(1), "file": rel})

        if "/health" in lowered or "healthz" in lowered or "health_check" in lowered:
            result["has_healthcheck"] = True

        for m in URL_RE.finditer(text):
            url = m.group(0).rstrip(".,);'\"")
            if not any(h in url for h in _LOCAL_HOSTS):
                endpoints.add(url[:200])

    result["detected"] = {k: sorted(v) for k, v in found.items()}
    result["deployment_assets"] = sorted(assets)
    # The list is capped for payload size, so the true total is recorded
    # separately — reporting the capped length as the count would understate it.
    result["external_endpoint_count"] = len(endpoints)
    result["external_endpoints"] = sorted(endpoints)[:80]
    result["languages"] = dict(sorted(langs.items(), key=lambda kv: -kv[1]))
    result["evidence"] = evidence
    # Duplicate route hits across files are common; keep the list bounded.
    result["api_routes"] = result["api_routes"][:120]
    result["secret_findings"] = result["secret_findings"][:60]

    result["components"] = _derive_components(result)
    return result


def _derive_components(scan: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Turn detections into component records.

    Only the eight component types the scanner can actually evidence are
    emitted. The specification listed twenty; the missing ones (prompt stores,
    business workflows) are not statically detectable, and offering them would
    imply a capability that does not exist.
    """
    comps: List[Dict[str, Any]] = []
    det = scan.get("detected", {})
    ev = scan.get("evidence", {})

    for label in det.get("app_framework", []):
        comps.append(make_component("APPLICATION", label, framework=label,
                                    location=ev.get(f"app_framework:{label}", ""), source="scan"))
    for label in det.get("ai_framework", []):
        comps.append(make_component("AGENT", label, framework=label,
                                    location=ev.get(f"ai_framework:{label}", ""), source="scan"))
    for label in det.get("model_runtime", []):
        comps.append(make_component("MODEL", label, runtime=label,
                                    location=ev.get(f"model_runtime:{label}", ""), source="scan"))
    for label in det.get("vector_store", []):
        comps.append(make_component("VECTOR_DATABASE", label,
                                    location=ev.get(f"vector_store:{label}", ""), source="scan"))
    for label in det.get("database", []):
        comps.append(make_component("DATABASE", label,
                                    location=ev.get(f"database:{label}", ""), source="scan"))
    for nb in scan.get("notebooks", [])[:20]:
        comps.append(make_component("NOTEBOOK", Path(nb).name, location=nb, source="scan"))
    if "Dockerfile" in scan.get("deployment_assets", []):
        comps.append(make_component("CONTAINER", "Dockerfile", location="Dockerfile", source="scan"))
    if scan.get("api_routes"):
        comps.append(make_component(
            "API", f"{len(scan['api_routes'])} route(s)",
            location=scan["api_routes"][0].get("file", ""), source="scan"))
    return comps
