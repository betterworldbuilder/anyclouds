#!/usr/bin/env python3
"""Concurrent dry run for the role-aware OpenCenter Quick Start sandbox."""

import io
import os
import shutil
import tempfile
import threading
import unittest
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


LAB_ROOT = tempfile.mkdtemp(prefix="opencenter-five-user-dry-run-")
os.environ["OPENCENTER_TRAINING_LAB_ROOT"] = LAB_ROOT
os.environ["OPENCENTER_TRAINING_MAX_COMMANDS"] = "8"
os.environ["OPENCENTER_TRUST_SSO_HEADERS"] = "1"
os.environ["OPENCENTER_TRAINING_DEFAULT_COHORT"] = "Five User Dry Run"
os.environ["FLASK_SECRET_KEY"] = "test-only-opencenter-lab-secret"
os.environ["WORKFLOW_DASHBOARD_DISABLE_SELF_RESTART"] = "1"

from workflow_dashboard.app import app  # noqa: E402


class OpenCenterFiveUserDryRun(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        app.config.update(TESTING=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(LAB_ROOT, ignore_errors=True)

    def exercise_user(self, number, role, barrier):
        client = app.test_client()
        self.assertEqual(client.get("/api/opencenter/lab-session").status_code, 401)

        name = f"{role} {number}"
        login = client.post(
            "/api/opencenter/training-login",
            json={"name": name, "role": role},
        )
        self.assertEqual(login.status_code, 200, login.get_data(as_text=True))
        self.assertEqual(login.get_json()["role"], role)

        info_response = client.get("/api/opencenter/lab-session")
        self.assertEqual(info_response.status_code, 200)
        info = info_response.get_json()
        self.assertEqual(info["learner"], name)
        self.assertEqual(info["role"], role)
        headers = {"X-OpenCenter-Lab-CSRF": info["csrf"]}
        org = info["suggested_org"]
        cluster = info["suggested_cluster"]
        unique_secret = f"five-user-secret-{number}"
        config_path = (
            f"$HOME/.config/opencenter/clusters/blueprints/"
            f"{org}/{cluster}/{cluster}-config.yaml"
        )

        saved = client.post(
            "/api/openrc/save-config",
            headers=headers,
            json={
                "path": config_path,
                "content": (
                    f"name: {cluster}\n"
                    f"learner: {number}\n"
                    f"password: {unique_secret}\n"
                ),
            },
        )
        self.assertEqual(saved.status_code, 200, saved.get_data(as_text=True))

        read_back = client.get(
            "/api/openrc/read-config",
            query_string={"path": config_path},
            headers=headers,
        )
        self.assertEqual(read_back.status_code, 200)
        self.assertIn(unique_secret, read_back.get_json()["content"])

        barrier.wait(timeout=15)
        command = client.post(
            "/api/stream/run-cmd",
            headers=headers,
            json={"command_id": "ocqs-cmd-pre-git", "cmd": "git --version"},
            buffered=True,
        )
        self.assertEqual(command.status_code, 200, command.get_data(as_text=True))
        command_text = command.get_data(as_text=True)
        self.assertIn("git version", command_text)
        self.assertIn("[EXIT 0]", command_text)

        published = client.post(
            "/api/opencenter/lab-result",
            headers=headers,
            json={
                "org": org,
                "cluster": cluster,
                "provider": "openstack",
                "completed_checks": number + 8,
                "role": "Instructor",
                "readiness": {"deployment_verified": number % 2 == 0},
            },
        )
        self.assertEqual(published.status_code, 200, published.get_data(as_text=True))
        self.assertEqual(published.get_json()["result"]["role"], role)

        feedback = client.post(
            "/api/opencenter/lab-feedback",
            headers=headers,
            json={
                "kind": "not_working" if number == 4 else "improvement",
                "stage": f"Stage {number + 1}",
                "message": f"Dry-run feedback from learner {number}.",
            },
        )
        self.assertEqual(feedback.status_code, 200, feedback.get_data(as_text=True))

        exported = client.get(
            "/api/opencenter/export-bundle",
            query_string={"org": org, "cluster": cluster},
            headers=headers,
        )
        self.assertEqual(exported.status_code, 200)
        with zipfile.ZipFile(io.BytesIO(exported.data)) as bundle:
            combined = b"\n".join(bundle.read(name) for name in bundle.namelist())
        self.assertNotIn(unique_secret.encode(), combined)
        self.assertIn(b"REDACTED_FOR_TRAINING_EXPORT", combined)

        with client.session_transaction() as learner_session:
            home = (
                Path(LAB_ROOT)
                / learner_session["opencenter_lab_identity"]
                / learner_session["opencenter_lab_id"]
                / "home"
            )
        return {
            "client": client,
            "headers": headers,
            "info": info,
            "home": home,
            "config_path": config_path,
            "role": role,
        }

    def test_five_simultaneous_role_sessions_and_cohort_review(self):
        barrier = threading.Barrier(5)
        roles = ["Instructor", "Student", "Student", "Student", "Student"]
        with ThreadPoolExecutor(max_workers=5) as executor:
            futures = [
                executor.submit(self.exercise_user, number, role, barrier)
                for number, role in enumerate(roles)
            ]
            users = [future.result(timeout=90) for future in futures]

        self.assertEqual(len({user["info"]["lab_id"] for user in users}), 5)
        self.assertEqual(len({str(user["home"]) for user in users}), 5)
        for user in users:
            self.assertTrue(user["home"].is_dir())

        other_config = (
            users[1]["home"]
            / ".config"
            / "opencenter"
            / "clusters"
            / "blueprints"
            / users[1]["info"]["suggested_org"]
            / users[1]["info"]["suggested_cluster"]
            / f"{users[1]['info']['suggested_cluster']}-config.yaml"
        )
        cross_read = users[0]["client"].get(
            "/api/openrc/read-config",
            query_string={"path": str(other_config)},
            headers=users[0]["headers"],
        )
        self.assertEqual(cross_read.status_code, 400)

        for user in users:
            review = user["client"].get(
                "/api/opencenter/cohort-review",
                headers=user["headers"],
            )
            self.assertEqual(review.status_code, 200)
            data = review.get_json()
            self.assertEqual(len(data["results"]), 5)
            self.assertEqual(len(data["feedback"]), 5)
            self.assertEqual(data["viewer_role"], user["role"])
            self.assertNotIn("five-user-secret", str(data))

        sso_override = users[1]["client"].get(
            "/api/opencenter/lab-session",
            headers={
                "X-Forwarded-User": "sso.instructor@example.com",
                "X-Auth-Request-Groups": "students,instructor",
                "X-Training-Cohort": "Five User Dry Run",
            },
        )
        self.assertEqual(sso_override.status_code, 200)
        self.assertTrue(sso_override.get_json()["sso_authenticated"])
        self.assertEqual(sso_override.get_json()["role"], "Instructor")
        self.assertEqual(sso_override.get_json()["learner"], "sso.instructor@example.com")


if __name__ == "__main__":
    unittest.main(verbosity=2)
