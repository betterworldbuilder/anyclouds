import requests


class BlueGreenCutoverClient:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")

    def configure(
        self,
        source_url: str,
        target_url: str,
        source_name: str = "source-blue",
        target_name: str = "target-green",
        health_path: str = "/health",
        smoke_path: str = "/",
    ):
        payload = {
            "active_environment": "source",
            "traffic_mode": "simulation",
            "source": {
                "name": source_name,
                "base_url": source_url,
                "health_path": health_path,
                "smoke_path": smoke_path,
                "expected_status": 200,
                "timeout_seconds": 5,
            },
            "target": {
                "name": target_name,
                "base_url": target_url,
                "health_path": health_path,
                "smoke_path": smoke_path,
                "expected_status": 200,
                "timeout_seconds": 5,
            },
        }
        response = requests.post(f"{self.base_url}/config", json=payload, timeout=10)
        response.raise_for_status()
        return response.json()

    def health_check(self):
        response = requests.get(f"{self.base_url}/health-check", timeout=20)
        response.raise_for_status()
        return response.json()

    def smoke_test(self):
        response = requests.get(f"{self.base_url}/smoke-test", timeout=20)
        response.raise_for_status()
        return response.json()

    def pre_cutover_check(self):
        response = requests.post(f"{self.base_url}/pre-cutover-check", timeout=30)
        response.raise_for_status()
        return response.json()

    def switch_to_target(self):
        response = requests.post(
            f"{self.base_url}/switch",
            json={"target_environment": "target", "require_target_healthy": True},
            timeout=20,
        )
        response.raise_for_status()
        return response.json()

    def switch_to_source(self):
        response = requests.post(
            f"{self.base_url}/switch",
            json={"target_environment": "source", "require_target_healthy": True},
            timeout=20,
        )
        response.raise_for_status()
        return response.json()

    def rollback(self, reason: str = "Migration app requested rollback"):
        response = requests.post(f"{self.base_url}/rollback", json={"reason": reason}, timeout=20)
        response.raise_for_status()
        return response.json()

    def audit_log(self):
        response = requests.get(f"{self.base_url}/audit", timeout=10)
        response.raise_for_status()
        return response.json()
